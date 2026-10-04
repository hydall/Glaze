"""Unit tests for the bug-triage agent (stdlib `unittest`, no network).

Run:  python -m unittest discover -s tools/bug_triage -p 'test_*.py'

Everything that talks to Discord, Trello or DeepSeek is faked. What is actually
under test is the logic that decides *which* card gets looked at and *what* the
model is shown — the part that silently rots when a rule changes.
"""

from __future__ import annotations

import unittest
from unittest import mock

import audit_comment
import images
import mirror
import subjects
import trello_client
from audit_pass import AuditPass
from config import Config
from discord_client import DiscordClient, ForumPost
from images import ImageRef, LoadedImage
from runner import AuditRunner
from trello_client import Card, Comment

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 32
JPEG = b"\xff\xd8\xff" + b"0" * 32


def make_config(**over) -> Config:
    base = dict(
        deepseek_api_key="k",
        deepseek_base_url="https://api.deepseek.com",
        deepseek_model="deepseek-chat",
        deepseek_vision_model="deepseek-v4-flash-vision-exp",
        trello_key="tk",
        trello_token="tt",
        trello_board_id="b",
        trello_new_bug_list_id="new",
        trello_audited_label_id="lbl",
        trello_audit_list_ids=("todo",),  # the list make_card() puts cards in
        trello_skip_list_ids=(),
        discord_bot_token="d",
        discord_guild_id="g",
        discord_forum_channel_id="f",
        discord_ignored_tag_ids=(),
        discord_skip_archived=True,
        dry_run=False,
        match_existing_cards=False,
        max_match_candidates=20,
        max_new_cards_per_run=25,
        max_audits_per_run=15,
        vision_enabled=True,
        max_images_per_audit=4,
        max_image_bytes=8_000_000,
        reaudit_image_blocked=True,
        max_reaudits_per_run=10,
        audit_board_cards=True,
        max_board_audits_per_run=10,
    )
    base.update(over)
    return Config(**base)


def make_card(cid="c1", name="Card", desc="", labels=(), **kw) -> Card:
    return Card(
        id=cid, name=name, desc=desc, list_id=kw.pop("list_id", "todo"),
        label_ids=tuple(labels), url=kw.pop("url", "https://trello.com/c/x"),
        attachment_count=kw.pop("attachment_count", 0),
        comment_count=kw.pop("comment_count", 0),
    )


def make_comment(text: str, author: str = "human") -> Comment:
    return Comment(id="a1", text=text, author=author, author_id="m1", date="")


class FakeTrello:
    """Records writes; serves canned comments/attachments per card id."""

    def __init__(self, comments=None, attachments=None):
        self._comments = comments or {}
        self._attachments = attachments or {}
        self.comments_posted: list[tuple[str, str]] = []
        self.labels: list[tuple[str, str]] = []
        self.comment_reads = 0

    def fetch_comments(self, card):
        self.comment_reads += 1
        return list(self._comments.get(card.id, []))

    def fetch_attachments(self, card):
        return list(self._attachments.get(card.id, []))

    def add_comment(self, card_id, text):
        self.comments_posted.append((card_id, text))

    def add_label(self, card_id, label_id):
        self.labels.append((card_id, label_id))


class FakeRunner:
    """Stands in for AuditRunner: records subjects, returns a canned verdict."""

    def __init__(self, result=None, boom=False):
        from runner import AuditResult

        self.seen: list = []
        self.boom = boom
        self.result = result or AuditResult(
            comment="verdict " + audit_comment.marker("vision", 1, False),
            mode="vision", images=1, needs_more_info=False,
        )

    def audit(self, subject):
        self.seen.append(subject)
        if self.boom:
            raise RuntimeError("model exploded")
        return self.result


# --------------------------------------------------------------------------
class SniffTest(unittest.TestCase):
    def test_supported_formats(self):
        self.assertEqual(images._sniff(PNG), "image/png")
        self.assertEqual(images._sniff(JPEG), "image/jpeg")
        self.assertEqual(images._sniff(b"GIF89a...."), "image/gif")
        self.assertEqual(images._sniff(b"RIFF1234WEBPxx"), "image/webp")

    def test_rejects_everything_else(self):
        self.assertIsNone(images._sniff(b"%PDF-1.7"))
        self.assertIsNone(images._sniff(b""))

    def test_dedup_keeps_first_occurrence(self):
        a = ImageRef("http://x/1.png", "a", "post")
        b = ImageRef("http://x/1.png", "b", "reply")
        c = ImageRef("http://x/2.png", "c", "reply")
        self.assertEqual(images.dedup([a, b, c]), [a, c])


class ImageLoaderTest(unittest.TestCase):
    def setUp(self):
        self.loader = images.ImageLoader("tk", "tt", max_bytes=100)

    def test_trello_urls_get_oauth_the_others_get_nothing(self):
        head = self.loader._headers("https://trello.com/1/cards/x/attachments/y")
        self.assertIn("oauth_consumer_key=\"tk\"", head["Authorization"])
        self.assertEqual(self.loader._headers("https://cdn.discordapp.com/a.png"), {})

    def test_oversized_and_unsupported_images_are_dropped(self):
        with mock.patch.object(images.ImageLoader, "_download") as dl:
            dl.return_value = None
            got = self.loader.load([ImageRef("http://x/1.png")], limit=4)
        self.assertEqual(got, [])

    def test_cap_stops_at_the_limit_and_download_happens_once(self):
        loaded = LoadedImage(ImageRef("u"), PNG, "image/png")
        with mock.patch.object(
            images.ImageLoader, "_download", return_value=loaded
        ) as dl:
            refs = [ImageRef(f"http://x/{i}.png") for i in range(5)]
            got = self.loader.load(refs, limit=2)
            # The same URL twice must not hit the network twice.
            self.loader.load([refs[0]], limit=2)
        self.assertEqual(len(got), 2)
        self.assertEqual(dl.call_count, 2)


class MarkerTest(unittest.TestCase):
    def test_marker_round_trip(self):
        state = audit_comment.read_state(
            [make_comment(audit_comment.marker("vision", 3, False))]
        )
        self.assertEqual(
            (state.audited, state.mode, state.images_seen, state.blocked_on_images),
            (True, "vision", 3, False),
        )

    def test_legacy_comments_are_recognised(self):
        blocked = audit_comment.read_state(
            [make_comment("⚠️ **NEED MORE INFO** — screenshots only")]
        )
        self.assertTrue(blocked.wants_vision)
        done = audit_comment.read_state([make_comment("🤖 **Automated audit** ...")])
        self.assertFalse(done.wants_vision)

    def test_last_comment_wins_and_vision_retires_the_card(self):
        state = audit_comment.read_state([
            make_comment("⚠️ **NEED MORE INFO** — screenshots only"),
            make_comment("a human replying"),
            make_comment("verdict " + audit_comment.marker("vision", 2, True)),
        ])
        self.assertTrue(state.blocked_on_images)
        self.assertFalse(state.wants_vision)  # vision already had its chance

    def test_human_comments_are_not_ours(self):
        self.assertFalse(audit_comment.is_triage_comment("looks like a dupe of #4"))
        self.assertTrue(
            audit_comment.is_triage_comment("x " + audit_comment.marker("text", 0, True))
        )

    def test_every_posted_comment_carries_a_marker(self):
        self.assertIn("glaze-triage:v2", audit_comment.unreadable("http://x", 2))
        audit = mock.Mock(
            needs_more_info=False, is_actionable=True, severity="high",
            summary="s", root_cause="r", proposed_fix="f", relevant_files=["a.dart"],
            confidence="high", notes="", image_findings="a red error dialog",
        )
        text = audit_comment.render(audit, "http://x", "vision", [ImageRef("u")])
        self.assertIn("glaze-triage:v2 mode=vision images=1 blocked=no", text)
        self.assertIn("a red error dialog", text)


class TrelloParsingTest(unittest.TestCase):
    def test_badges_become_counts(self):
        card = trello_client._card_from_json({
            "id": "1", "name": "n", "desc": "d", "idList": "l", "idLabels": ["x"],
            "shortUrl": "http://t/c", "badges": {"attachments": 2, "comments": 3},
        })
        self.assertEqual((card.attachment_count, card.comment_count), (2, 3))
        self.assertFalse(card.is_discord_linked)

    def test_markers_are_stripped_from_the_report_text(self):
        desc = "It crashes\n\n---\nReported on Discord: http://d/1\ndiscord-thread:42"
        self.assertEqual(trello_client.strip_markers(desc), "It crashes")
        self.assertEqual(make_card(desc=desc).discord_thread_ids, ("42",))

    def test_image_links_in_text(self):
        refs = trello_client.image_refs_in_text(
            "see https://trello.com/1/cards/a/attachments/b/download/x.png and "
            "http://e.com/doc.pdf",
            "comment",
        )
        self.assertEqual([r.url for r in refs],
                         ["https://trello.com/1/cards/a/attachments/b/download/x.png"])


class DiscordImageTest(unittest.TestCase):
    def test_only_images_are_collected(self):
        msg = {
            "attachments": [
                {"url": "http://c/a.png", "content_type": "image/png",
                 "filename": "a.png"},
                {"url": "http://c/log.txt", "content_type": "text/plain",
                 "filename": "log.txt"},
                {"url": "http://c/b.JPG", "filename": "b.JPG"},  # no content_type
            ],
            "embeds": [{"type": "image", "image": {"url": "http://e/i.webp"}}],
        }
        refs = DiscordClient._image_refs(msg, "original post")
        self.assertEqual([r.url for r in refs],
                         ["http://c/a.png", "http://c/b.JPG", "http://e/i.webp"])


class SubjectTest(unittest.TestCase):
    def test_card_subject_drops_our_own_comments_but_keeps_humans(self):
        card = make_card(desc="Broken since 0.7", comment_count=2)
        subject = subjects.from_card(
            card,
            [
                make_comment("also on Android", "bob"),
                make_comment("verdict " + audit_comment.marker("text", 0, True), "bot"),
            ],
            [ImageRef("http://t/x.png", "x.png", "card attachment")],
        )
        self.assertEqual(subject.replies, ("bob: also on Android",))
        self.assertEqual(len(subject.images), 1)
        self.assertIn("Card", subject.text)  # the title counts as report text

    def test_comment_image_links_join_the_attachments(self):
        card = make_card(comment_count=1)
        subject = subjects.from_card(
            card, [make_comment("here: http://e/shot.png", "bob")], []
        )
        self.assertEqual([r.url for r in subject.images], ["http://e/shot.png"])

    def test_report_announces_only_the_images_actually_attached(self):
        post = ForumPost("1", "Crash", "boom", (), 2, "http://d/1",
                         (ImageRef("u1", "a.png", "original post"),
                          ImageRef("u2", "b.png", "reply by bob")))
        subject = subjects.from_post(post)
        with_one = subject.report([post.images[0]])
        self.assertIn("Image 1: a.png (original post)", with_one)
        self.assertNotIn("b.png", with_one)
        self.assertIn("none of them is available to you", subject.report())


class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.cfg = make_config()
        self.loader = mock.Mock()
        self.runner = AuditRunner(self.cfg, self.loader)
        self.audit = mock.Mock(needs_more_info=False, is_actionable=True,
                               severity="low", summary="s", root_cause="r",
                               proposed_fix="f", relevant_files=[], confidence="low",
                               notes="", image_findings="")

    def _subject(self, text="a real report, long enough", imgs=()):
        return subjects.AuditSubject(
            key="k", kind="Trello card", title="T", body=text, replies=(),
            images=tuple(imgs), source_url="http://x",
        )

    def test_no_text_and_no_image_never_calls_the_model(self):
        self.loader.load.return_value = []
        with mock.patch("runner.run") as run:
            result = self.runner.audit(self._subject(text="", imgs=[]))
        run.assert_not_called()
        self.assertEqual(result.mode, "none")
        self.assertTrue(result.needs_more_info)

    def test_images_route_to_the_vision_model(self):
        loaded = [LoadedImage(ImageRef("u", "a.png"), PNG, "image/png")]
        self.loader.load.return_value = loaded
        with mock.patch("runner.build_agent") as build, \
             mock.patch("runner.run", return_value=self.audit) as run:
            result = self.runner.audit(self._subject(imgs=[ImageRef("u")]))
        self.assertEqual(build.call_args.args[2], self.cfg.deepseek_vision_model)
        self.assertTrue(build.call_args.kwargs["can_see_images"])
        self.assertEqual(run.call_args.args[2], loaded)
        self.assertEqual((result.mode, result.images), ("vision", 1))

    def test_a_failing_vision_call_falls_back_to_text(self):
        self.loader.load.return_value = [
            LoadedImage(ImageRef("u", "a.png"), PNG, "image/png")
        ]
        with mock.patch("runner.build_agent"), \
             mock.patch("runner.run", side_effect=[RuntimeError("400"), self.audit]):
            result = self.runner.audit(self._subject(imgs=[ImageRef("u")]))
        self.assertEqual((result.mode, result.images), ("text", 0))

    def test_vision_disabled_keeps_the_old_behaviour(self):
        runner = AuditRunner(make_config(vision_enabled=False), self.loader)
        with mock.patch("runner.build_agent") as build, \
             mock.patch("runner.run", return_value=self.audit):
            runner.audit(self._subject(imgs=[ImageRef("u")]))
        self.loader.load.assert_not_called()
        self.assertEqual(build.call_args.args[2], self.cfg.deepseek_model)


class ImageBlockedPassTest(unittest.TestCase):
    """Pass 2 — the backlog of cards a blind model could not judge."""

    def _pass(self, cards, comments, attachments=None, cfg=None):
        trello = FakeTrello(comments, attachments)
        runner = FakeRunner()
        passes = AuditPass(cfg or make_config(), trello, runner)
        return passes, trello, runner, cards

    def test_a_blocked_card_with_a_picture_is_audited_again(self):
        card = make_card("c1", "Crash", labels=("lbl",), comment_count=1,
                         attachment_count=1)
        passes, trello, runner, cards = self._pass(
            [card],
            {"c1": [make_comment("⚠️ **NEED MORE INFO** — screenshots only")]},
            {"c1": [ImageRef("http://t/x.png", "x.png", "card attachment")]},
        )
        passes.image_blocked(cards, {})
        self.assertEqual(len(runner.seen), 1)
        self.assertEqual(trello.comments_posted[0][0], "c1")
        # Already labelled — the pass must not label it twice.
        self.assertEqual(trello.labels, [])

    def test_a_blocked_card_without_any_picture_is_left_alone(self):
        card = make_card("c1", "Vague", labels=("lbl",), comment_count=1)
        passes, trello, runner, cards = self._pass(
            [card], {"c1": [make_comment("⚠️ **NEED MORE INFO** — no repro steps")]}
        )
        passes.image_blocked(cards, {})
        self.assertEqual(runner.seen, [])
        self.assertEqual(trello.comments_posted, [])

    def test_a_card_the_vision_model_already_saw_is_not_reopened(self):
        card = make_card("c1", "Crash", labels=("lbl",), comment_count=1,
                         attachment_count=1)
        passes, trello, runner, cards = self._pass(
            [card],
            {"c1": [make_comment("v " + audit_comment.marker("vision", 2, True))]},
            {"c1": [ImageRef("http://t/x.png")]},
        )
        passes.image_blocked(cards, {})
        self.assertEqual(runner.seen, [])

    def test_a_linked_card_is_re_read_from_its_discord_thread(self):
        card = make_card("c1", "Crash", desc="discord-thread:42",
                         labels=("lbl",), comment_count=1)
        post = ForumPost("42", "Crash", "see pic", (), 1, "http://d/42",
                         (ImageRef("http://cdn/s.png", "s.png", "original post"),))
        passes, trello, runner, cards = self._pass(
            [card], {"c1": [make_comment("⚠️ **NEED MORE INFO**")]}
        )
        passes.image_blocked(cards, {"42": post})
        self.assertEqual(len(runner.seen), 1)
        self.assertEqual(runner.seen[0].key, "42")  # the thread, not the card

    def test_the_whole_pass_is_off_when_vision_is(self):
        card = make_card("c1", "Crash", labels=("lbl",), comment_count=1,
                         attachment_count=1)
        passes, trello, runner, cards = self._pass(
            [card],
            {"c1": [make_comment("⚠️ **NEED MORE INFO** — screenshots only")]},
            {"c1": [ImageRef("http://t/x.png")]},
            cfg=make_config(vision_enabled=False),
        )
        passes.image_blocked(cards, {})
        self.assertEqual(runner.seen, [])
        self.assertEqual(trello.comment_reads, 0)  # not even a board read

    def test_a_blocked_card_outside_the_audit_lists_is_left_alone(self):
        card = make_card("c1", "Crash", labels=("lbl",), comment_count=1,
                         attachment_count=1, list_id="ideas")
        passes, trello, runner, cards = self._pass(
            [card],
            {"c1": [make_comment("⚠️ **NEED MORE INFO** — screenshots only")]},
            {"c1": [ImageRef("http://t/x.png", "x.png", "card attachment")]},
        )
        passes.image_blocked(cards, {})
        self.assertEqual(runner.seen, [])
        self.assertEqual(trello.comments_posted, [])

    def test_the_cap_stops_the_pass(self):
        cards = [
            make_card(f"c{i}", "Crash", labels=("lbl",), comment_count=1,
                      attachment_count=1)
            for i in range(4)
        ]
        comments = {c.id: [make_comment("⚠️ **NEED MORE INFO**")] for c in cards}
        attach = {c.id: [ImageRef(f"http://t/{c.id}.png")] for c in cards}
        passes, trello, runner, cards = self._pass(
            cards, comments, attach, cfg=make_config(max_reaudits_per_run=2)
        )
        passes.image_blocked(cards, {})
        self.assertEqual(len(runner.seen), 2)


class BoardPassTest(unittest.TestCase):
    """Pass 3 — cards nobody mirrored from Discord and nobody audited."""

    def test_hand_written_unlabelled_cards_are_audited_and_labelled(self):
        card = make_card("c1", "Audio cuts out", desc="since 0.7")
        trello, runner = FakeTrello(), FakeRunner()
        AuditPass(make_config(), trello, runner).board([card])
        self.assertEqual([s.key for s in runner.seen], ["c1"])
        self.assertEqual(trello.labels, [("c1", "lbl")])

    def test_linked_or_audited_or_skip_listed_cards_are_left_alone(self):
        cards = [
            make_card("c1", desc="discord-thread:7"),          # the forum owns it
            make_card("c2", labels=("lbl",)),                   # already audited
            make_card("c3", list_id="done"),                    # excluded column
        ]
        trello, runner = FakeTrello(), FakeRunner()
        cfg = make_config(trello_skip_list_ids=("done",))
        AuditPass(cfg, trello, runner).board(cards)
        self.assertEqual(runner.seen, [])

    def test_only_cards_in_the_audit_lists_are_swept(self):
        cards = [
            make_card("c1", "Crash", list_id="bugs"),      # in scope
            make_card("c2", "Folders", list_id="ideas"),   # a feature column
            make_card("c3", "Redesign", list_id="todo"),   # another one
        ]
        trello, runner = FakeTrello(), FakeRunner()
        cfg = make_config(trello_audit_list_ids=("bugs",))
        AuditPass(cfg, trello, runner).board(cards)
        self.assertEqual([s.key for s in runner.seen], ["c1"])
        self.assertEqual(trello.labels, [("c1", "lbl")])

    def test_a_card_audited_before_the_label_existed_is_not_redone(self):
        card = make_card("c1", comment_count=1)
        trello = FakeTrello({"c1": [make_comment("🤖 **Automated audit** — ...")]})
        runner = FakeRunner()
        AuditPass(make_config(), trello, runner).board([card])
        self.assertEqual(runner.seen, [])

    def test_one_card_is_never_audited_by_two_passes(self):
        card = make_card("c1", "Crash", comment_count=1, attachment_count=1)
        trello = FakeTrello(
            {"c1": [make_comment("⚠️ **NEED MORE INFO** — screenshots only")]},
            {"c1": [ImageRef("http://t/x.png")]},
        )
        runner = FakeRunner()
        passes = AuditPass(make_config(), trello, runner)
        passes.image_blocked([card], {})
        passes.board([card])
        self.assertEqual(len(runner.seen), 1)

    def test_the_cap_stops_the_pass(self):
        cards = [make_card(f"c{i}", "Bug") for i in range(5)]
        trello, runner = FakeTrello(), FakeRunner()
        cfg = make_config(max_board_audits_per_run=2)
        AuditPass(cfg, trello, runner).board(cards)
        self.assertEqual(len(runner.seen), 2)

    def test_a_failing_audit_is_counted_not_raised(self):
        trello, runner = FakeTrello(), FakeRunner(boom=True)
        passes = AuditPass(make_config(), trello, runner)
        passes.board([make_card("c1")])
        self.assertEqual(passes.failures, 1)
        self.assertEqual(trello.comments_posted, [])

    def test_has_work_is_false_on_a_fully_audited_board(self):
        cards = [make_card("c1", labels=("lbl",)), make_card("c2", desc="discord-thread:7")]
        passes = AuditPass(make_config(), FakeTrello(), FakeRunner())
        self.assertFalse(passes.has_work(cards))

    def test_has_work_spots_a_hand_written_card(self):
        passes = AuditPass(make_config(), FakeTrello(), FakeRunner())
        self.assertTrue(passes.has_work([make_card("c1")]))

    def test_has_work_ignores_cards_outside_the_audit_lists(self):
        cards = [make_card("c1", list_id="ideas"), make_card("c2", list_id="done")]
        passes = AuditPass(make_config(), FakeTrello(), FakeRunner())
        self.assertFalse(passes.has_work(cards))

    def test_card_reads_are_cached_across_passes(self):
        card = make_card("c1", comment_count=1)
        trello = FakeTrello({"c1": [make_comment("human note")]})
        passes = AuditPass(make_config(), trello, FakeRunner())
        passes.has_work([card])
        passes.board([card])
        self.assertEqual(trello.comment_reads, 1)


class ConfigScopeTest(unittest.TestCase):
    """`TRELLO_AUDIT_LIST_IDS` — what the board passes are allowed to touch."""

    ENV = {
        "DEEPSEEK_API_KEY": "k",
        "TRELLO_KEY": "tk",
        "TRELLO_TOKEN": "tt",
        "TRELLO_BOARD_ID": "b",
        "TRELLO_NEW_BUG_LIST_ID": "newbugs",
        "TRELLO_AUDITED_LABEL_ID": "lbl",
        "DISCORD_BOT_TOKEN": "d",
        "DISCORD_GUILD_ID": "g",
        "DISCORD_FORUM_CHANNEL_ID": "f",
    }

    def _load(self, **over):
        with mock.patch.dict("os.environ", {**self.ENV, **over}, clear=True):
            return Config.load()

    def test_unset_means_the_new_bug_list_alone(self):
        self.assertEqual(self._load().trello_audit_list_ids, ("newbugs",))

    def test_an_empty_var_is_not_an_empty_scope(self):
        # GitHub expands an undefined vars.X to "" — that must not silently
        # mean "no list is in scope", which would switch both passes off.
        cfg = self._load(TRELLO_AUDIT_LIST_IDS="")
        self.assertEqual(cfg.trello_audit_list_ids, ("newbugs",))

    def test_the_var_replaces_the_default(self):
        cfg = self._load(TRELLO_AUDIT_LIST_IDS="bugs, regressions ")
        self.assertEqual(cfg.trello_audit_list_ids, ("bugs", "regressions"))


class MirrorBodyTest(unittest.TestCase):
    def test_the_footer_says_images_are_readable_now(self):
        post = ForumPost("1", "Crash", "boom", (), 2, "http://d/1",
                         (ImageRef("u", "a.png", "original post"),))
        body = mirror.card_body(post)
        self.assertIn("Attachments: 2, 1 of them image(s) the triage agent reads",
                      body)
        self.assertIn("discord-thread:1", body)

    def test_a_thread_with_no_readable_image_says_so(self):
        post = ForumPost("1", "Crash", "boom", (), 1, "http://d/1", ())
        self.assertIn("(no readable image among them)", mirror.card_body(post))


class EndToEndTest(unittest.TestCase):
    """One full `main()` with every boundary faked: does the wiring hold?"""

    def test_a_run_covers_all_three_passes(self):
        import triage

        post = ForumPost(
            thread_id="42", title="Crash on export", body="", replies=(),
            attachment_count=1, url="http://d/42",
            images=(ImageRef("http://cdn/s.png", "s.png", "original post"),),
        )
        blocked = make_card("c-blocked", "Old report", labels=("lbl",),
                            comment_count=1, attachment_count=1)
        hand = make_card("c-hand", "Audio cuts out", desc="since 0.7")

        trello = FakeTrello(
            {"c-blocked": [make_comment("⚠️ **NEED MORE INFO** — screenshots only")]},
            {"c-blocked": [ImageRef("http://t/x.png", "x.png", "card attachment")]},
        )
        trello.fetch_cards = lambda: [blocked, hand]
        trello.set_desc = lambda *a: None
        trello.create_card = lambda *a: "c-new"

        discord = mock.Mock()
        discord.fetch_posts.return_value = [post]

        audit = mock.Mock(needs_more_info=False, is_actionable=True, severity="low",
                          summary="s", root_cause="r", proposed_fix="f",
                          relevant_files=[], confidence="low", notes="",
                          image_findings="a red dialog")
        loaded = LoadedImage(ImageRef("u", "a.png"), PNG, "image/png")

        with mock.patch.object(triage.Config, "load", staticmethod(make_config)), \
             mock.patch.object(triage, "DiscordClient", return_value=discord), \
             mock.patch.object(triage, "TrelloClient", return_value=trello), \
             mock.patch.object(images.ImageLoader, "_download", return_value=loaded), \
             mock.patch("runner.build_agent"), \
             mock.patch("runner.run", return_value=audit) as run:
            self.assertEqual(triage.main(), 0)

        # One audit per pass: the new card, the blocked card, the hand-written one.
        commented = [cid for cid, _ in trello.comments_posted]
        self.assertEqual(commented, ["c-new", "c-blocked", "c-hand"])
        self.assertEqual(run.call_count, 3)
        # The screenshot-only thread reached a model instead of being written off.
        self.assertTrue(all(c.args[2] for c in run.call_args_list[:2]))
        for _, text in trello.comments_posted:
            self.assertIn("glaze-triage:v2", text)

    def test_a_quiet_board_never_builds_an_agent(self):
        import triage

        cards = [make_card("c1", labels=("lbl",), desc="discord-thread:7")]
        trello = FakeTrello()
        trello.fetch_cards = lambda: cards
        discord = mock.Mock()
        discord.fetch_posts.return_value = []

        with mock.patch.object(triage.Config, "load", staticmethod(make_config)), \
             mock.patch.object(triage, "DiscordClient", return_value=discord), \
             mock.patch.object(triage, "TrelloClient", return_value=trello), \
             mock.patch("runner.build_agent") as build:
            self.assertEqual(triage.main(), 0)
        build.assert_not_called()
        self.assertEqual(trello.comments_posted, [])


if __name__ == "__main__":
    unittest.main()
