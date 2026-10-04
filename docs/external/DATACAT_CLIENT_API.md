# DataCat Client API — Full Documentation

Verbatim reference copy of the official DataCat Client API documentation, for
offline reading. Original pages:

- <https://datacat.run/creatortools/api-access/documentation>
- OpenAPI 3.1 spec: <https://datacat.run/client-api-v1.openapi.json>
  (also saved next to this file as `DATACAT_CLIENT_API.openapi.json`)

Captured: 2026-09-21. API version: `v1` (experimental), spec version
`1.0.0-experimental`. Docs page footer: DataCat v0.98.

> Note: the original documentation page is rendered by JavaScript, so it cannot
> be read with a plain HTTP fetch. This file is the rendered text, cleaned up.

## Contents

- [Quick start](#quick-start)
- [Authentication and request structure](#authentication-and-request-structure)
- [Browser safety](#browser-safety)
- [Scopes](#scopes)
- [Common data models](#common-data-models)
- [Discovery](#discovery)
- [Creators](#creators)
- [Characters and files](#characters-and-files)
- [Community](#community)
- [Account linking](#account-linking)
- [Human verification](#human-verification)
- [Hosted and first-party routes](#hosted-and-first-party-routes)
- [Errors, pagination, and rate limits](#errors-pagination-and-rate-limits)

**CLIENT API V1 · EXPERIMENTAL**

**Base URL:** `https://datacat.run/api/client/v1`

- **Requests:** HTTPS with JSON query/body data
- **Responses:** JSON, except image and `204` endpoints

## Quick start

Approved integrations receive a public Client ID. Server-side integrations may
also create a developer bearer token from API Access. Keep bearer tokens private;
the Client ID is an identifier and is safe to send from a browser or installed
client.

### List characters

```bash
curl 'https://datacat.run/api/client/v1/characters?limit=20&search=wizard' \
  -H 'X-Datacat-Client-Id: YOUR_CLIENT_ID'
```

## Authentication and request structure

Send `X-Datacat-Client-Id` on scoped requests. Use a developer token (`dca1_…`)
for a trusted backend, or complete account linking to receive an
installation-bound user token (`dcv1_…`). Linked tokens must be sent with the
same installation ID.

Typical authenticated headers:

```
X-Datacat-Client-Id: YOUR_CLIENT_ID
Authorization: Bearer dca1_YOUR_DEVELOPER_TOKEN
Content-Type: application/json
```

Security schemes:

| Scheme | Header / format | Notes |
|---|---|---|
| ClientId | `X-Datacat-Client-Id` | Public identifier assigned to an approved integration. |
| BearerAuth | `Authorization: Bearer …` | Developer token (`dca1_`) or linked-installation token (`dcv1_`). |
| InstallationId | `X-Datacat-Installation-Id` | Stable, non-secret installation ID. |
| VerificationLease | `X-Datacat-Verification-Lease` | Short-lived lease for protected transfers. |

## Browser safety

Never ship a developer or linked-account bearer token in public browser
JavaScript. Browser clients may use the public Client ID for discovery and should
use the hosted account-link and verification flows for user-specific actions.

## Scopes

| Scope | Allows |
|---|---|
| `characters:read` | Character, creator, Fresh-feed, and tag discovery. |
| `cards:read` | Protected Character Card V2 JSON and mirrored image transfers. |
| `account:link` | Device account linking and account-status checks. |
| `community:read` | Character kudos and comments. |
| `community:write` | Giving kudos and posting comments as a logged-in user. |

## Common data models

Fields use camelCase. IDs are UUID strings, dates are ISO-8601 strings, and a
missing optional value is normally `null`. Additive fields may appear within v1,
so clients should ignore fields they do not recognize.

### CHARACTERSUMMARY

```json
{
  "id": "character UUID",
  "name": "Display name",
  "chatName": "Optional in-chat name",
  "creator": {
    "id": "creator UUID",
    "ref": "UUID or saucepan:UUID",
    "sourceKind": "janitor | saucepan | direct_upload",
    "name": "Creator name"
  },
  "description": "Plain-text summary",
  "tags": ["Fantasy"],
  "image": { "status": "ready | pending", "url": "https://... or null" },
  "avatarUrl": "https://... or null",
  "clientPaths": {
    "profile": "/characters/{id}?sourceKind=janitor_core",
    "card": "/characters/{id}/card?sourceKind=janitor_core",
    "avatar": "/characters/{id}/avatar?sourceKind=janitor_core",
    "avatarPreview": null
  },
  "sourceKind": "janitor_core",
  "nsfw": false,
  "stats": { "chats": 120, "messages": 1600, "messagesPerChat": 13.33 },
  "totalTokens": 2400,
  "score": 82.5,
  "publishedAt": "ISO-8601 timestamp or null",
  "updatedAt": "ISO-8601 timestamp or null"
}
```

### PAGING

```json
{
  "limit": 24,
  "offset": 0,
  "total": 240,
  "hasMore": true,
  "nextOffset": 24
}
```

### CREATORPROFILE

```json
{
  "id": "creator UUID",
  "ref": "UUID or saucepan:UUID",
  "sourceKind": "janitor | saucepan",
  "name": "Creator name",
  "handle": "optional handle",
  "avatarUrl": "https://... or null",
  "about": "Plain-text profile biography",
  "verified": true,
  "stats": { "characters": 42, "chats": 1000, "messages": 12000, "followers": 300 },
  "topTags": [{ "name": "Fantasy", "slug": "fantasy", "count": 12 }],
  "createdAt": "ISO-8601 timestamp or null",
  "updatedAt": "ISO-8601 timestamp or null"
}
```

## Discovery

### GET /capabilities — Inspect API capabilities

Returns enabled features, paging limits, rate-limit tiers, registration
requirements, and hosted verification settings.

Use it for: feature detection at client startup so an integration can adapt
without hard-coding server configuration.

- **Scope:** Public
- **Authentication:** None
- **Returns:** application/json

Request parameters: no path, query, or body parameters.

Request example:

```bash
curl 'https://datacat.run/api/client/v1/capabilities'
```

Response example:

```json
{
  "success": true,
  "apiVersion": "v1",
  "clientRegistration": {
    "required": true,
    "requestPath": "/creatortools/api-access",
    "clientIdHeader": "X-Datacat-Client-Id",
    "clientIdsAreSecrets": false,
    "developerToken": { "supported": true, "authorizationScheme": "Bearer" }
  },
  "features": { "listing": true, "tagBrowsing": true, "social": true },
  "paging": { "defaultPageSize": 24, "maxPageSize": 24 },
  "rateLimiting": { "enabled": true, "discovery": {}, "community": {}, "tiers": {} },
  "securityCheck": { "enabled": true, "hosted": true }
}
```

### GET /characters — Search and browse characters

Returns a page of public character summaries, optionally narrowed by text and tag
filters.

Use it for: search results, discovery grids, tag-filtered catalogs, and choosing
a character before loading its full profile.

- **Scope:** `characters:read`
- **Authentication:** Client ID; bearer token optional
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `search` | query | string ≤120 chars | No | Text to search for. |
| `tagIds` | query | CSV&lt;int&gt; ≤24 | No | Require all listed tag IDs. |
| `blockedTagIds` | query | CSV&lt;int&gt; ≤50 | No | Exclude characters with these tags. |
| `sort` | query | enum | No | `fresh`, `score`, `chat_count`, `messages_per_chat`, or `first_published`. |
| `limit` | query | integer | No | Page size, capped by `/capabilities`. |
| `offset` | query | integer 0…200000 | No | Zero-based page offset. |

Request example:

```bash
curl 'https://datacat.run/api/client/v1/characters?search=wizard&tagIds=12,44&limit=20' \
  -H 'X-Datacat-Client-Id: YOUR_CLIENT_ID'
```

Response example:

```json
{
  "success": true,
  "characters": [CharacterSummary],
  "paging": { "limit": 20, "offset": 0, "hasMore": true, "nextOffset": 20 },
  "filters": { "tagIds": [12, 44], "blockedTagIds": [], "search": "wizard", "sort": "fresh" }
}
```

### GET /fresh — Load the Fresh feed

Returns separate last-24-hours and this-week character windows with independent
pagination.

Use it for: new-release feeds where recent daily arrivals and the broader weekly
stream appear together.

- **Scope:** `characters:read`
- **Authentication:** Client ID; bearer token optional
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `limit` | query | integer | No | Maximum items in each time window. |
| `offset24` | query | integer | No | Offset for the last-24-hours window. |
| `offsetWeek` | query | integer | No | Offset for the this-week window. |
| `sort` | query | enum | No | The same character sort values accepted by `/characters`. |

Response example:

```json
{
  "success": true,
  "sortBy": "fresh",
  "windows": {
    "last24h": { "count": 8, "characters": [FreshCharacterSummary], "paging": Paging },
    "thisWeek": { "count": 24, "characters": [FreshCharacterSummary], "paging": Paging }
  }
}
```

### GET /tags — Browse tag facets

Returns tag groups and counts calculated against the currently active and
excluded filters.

Use it for: building a faceted tag picker whose counts stay relevant as the user
narrows the catalog.

- **Scope:** `characters:read`
- **Authentication:** Client ID; bearer token optional
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `activeTagIds` | query | CSV&lt;int&gt; ≤24 | No | Tags already required by the current search. |
| `blockedTagIds` | query | CSV&lt;int&gt; ≤50 | No | Tags excluded from the current search. |
| `search` | query | string ≤80 chars | No | Filter tag names and slugs. |
| `sort` | query | `count` \| `alpha` | No | Sort tags by use count or alphabetically. |
| `limit` | query | integer 20…250 | No | Number of tag rows. |
| `offset` | query | integer | No | Zero-based page offset. |

Response example:

```json
{
  "success": true,
  "groups": [{ "id": 1, "name": "Genre", "slug": "genre", "displayOrder": 1, "exclusive": false }],
  "tags": [{ "id": 12, "name": "Fantasy", "slug": "fantasy", "groupId": 1, "count": 2450 }],
  "filters": { "activeTagIds": [], "blockedTagIds": [], "search": null, "sort": "count" },
  "paging": Paging
}
```

## Creators

### GET /creators/{creatorRef}/bootstrap — Bootstrap a creator profile

Returns creator metadata and the first filtered page of that creator's characters
in one response.

Use it for: opening a creator screen with one request and avoiding a separate
profile-then-list waterfall.

- **Scope:** `characters:read`
- **Authentication:** Client ID; bearer token optional
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `creatorRef` | path | UUID \| `saucepan:UUID` | Yes | Stable creator reference. Prefix Saucepan creators with `saucepan:`. |
| `tagSlugs` | query | CSV&lt;string&gt; ≤24 | No | Require creator characters with all listed tags. |
| `blockedTagSlugs` | query | CSV&lt;string&gt; ≤50 | No | Exclude creator characters with these tags. |
| `sort` | query | enum | No | `creation_date`, `chat_count`, `message_count`, or `name`. |
| `sortDir` | query | `asc` \| `desc` | No | Sort direction; defaults to `desc`. |
| `limit` | query | integer 1…50 | No | Character page size. |
| `offset` | query | integer | No | Character page offset. |

Response example:

```json
{
  "success": true,
  "creatorRef": { "id": "UUID", "sourceKind": "janitor", "publicRef": "UUID" },
  "creator": CreatorProfile,
  "characters": [CharacterSummary],
  "paging": Paging,
  "filters": { "tagSlugs": [], "blockedTagSlugs": [], "sort": "creation_date", "sortDir": "desc" }
}
```

### GET /creators/{creatorRef}/characters — Page through a creator's characters

Returns the same filtered character page as bootstrap without repeating creator
profile metadata.

Use it for: infinite scrolling and changing sort or tag filters after a creator
screen is already open.

- **Scope:** `characters:read`
- **Authentication:** Client ID; bearer token optional
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `creatorRef` | path | UUID \| `saucepan:UUID` | Yes | Stable creator reference. |
| `tagSlugs` | query | CSV&lt;string&gt; ≤24 | No | Required tags. |
| `blockedTagSlugs` | query | CSV&lt;string&gt; ≤50 | No | Excluded tags. |
| `sort` | query | enum | No | `creation_date`, `chat_count`, `message_count`, or `name`. |
| `sortDir` | query | `asc` \| `desc` | No | Sort direction. |
| `limit` | query | integer 1…50 | No | Page size. |
| `offset` | query | integer | No | Page offset. |

Response example:

```json
{
  "success": true,
  "creatorRef": { "id": "UUID", "sourceKind": "saucepan", "publicRef": "saucepan:UUID" },
  "creator": null,
  "characters": [CharacterSummary],
  "paging": Paging,
  "filters": { "tagSlugs": ["fantasy"], "blockedTagSlugs": [], "sort": "name", "sortDir": "asc" }
}
```

## Characters and files

### GET /characters/{characterId} — Load a character profile

Returns full public character metadata, longer description text, complete tags,
custom tags, and creator notes.

Use it for: detail screens and deciding whether a character is suitable before
requesting protected card files.

- **Scope:** `characters:read`
- **Authentication:** Client ID; bearer token optional
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `characterId` | path | UUID | Yes | The stable DataCat character identifier. |
| `sourceKind` | query | string | No | Disambiguates `janitor`, `jannyai`, `saucepan`, or `direct_upload` content. |

Response example:

```json
{
  "success": true,
  "character": {
    "...CharacterSummary": "all CharacterSummary fields",
    "description": "Full plain-text description",
    "tags": ["Full", "tag", "objects or values from source"],
    "customTags": ["Custom tag"],
    "creatorNotes": "Creator notes"
  }
}
```

### GET /characters/{characterId}/avatar-preview — Display a direct-upload image

Streams a mirrored image for a public direct-upload character without consuming a
protected file-transfer allowance.

Use it for: rendering direct-upload thumbnails from the URL supplied in
`CharacterSummary.image.url`.

- **Scope:** Public direct-upload preview
- **Authentication:** None
- **Returns:** image/avif, image/gif, image/jpeg, image/png, or image/webp

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `characterId` | path | UUID | Yes | The stable DataCat character identifier. |
| `sourceKind` | query | string | Yes | Must identify `direct_upload` content. |

Response example: binary image body. Content-Type and Content-Length describe the
returned file.

### GET /characters/{characterId}/card — Download Character Card V2 JSON

Returns the importable character definition as Character Card V2 JSON and
enforces creator download policy.

Use it for: importing a character into a compatible chat client or saving a
portable card definition.

- **Scope:** `cards:read`
- **Authentication:** Client ID plus verification lease; bearer token optional
- **Returns:** application/json (Character Card V2)

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `characterId` | path | UUID | Yes | The stable DataCat character identifier. |
| `sourceKind` | query | string | No | Disambiguates `janitor`, `jannyai`, `saucepan`, or `direct_upload` content. |
| `X-Datacat-Verification-Lease` | header | string | Yes | Short-lived lease obtained from the hosted verification flow. |

Response example:

```json
{
  "spec": "chara_card_v2",
  "spec_version": "2.0",
  "data": {
    "name": "Character name",
    "description": "...",
    "personality": "...",
    "scenario": "...",
    "first_mes": "...",
    "mes_example": "..."
  }
}
```

### GET /characters/{characterId}/avatar — Download the mirrored character image

Streams DataCat's archived character image after authorization and creator-policy
checks.

Use it for: saving the original visual asset alongside an imported JSON card.

- **Scope:** `cards:read`
- **Authentication:** Client ID plus verification lease; bearer token optional
- **Returns:** Binary image

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `characterId` | path | UUID | Yes | The stable DataCat character identifier. |
| `sourceKind` | query | string | No | Disambiguates `janitor`, `jannyai`, `saucepan`, or `direct_upload` content. |
| `X-Datacat-Verification-Lease` | header | string | Yes | Short-lived verification lease. |

Response example: binary image body with Content-Type, Content-Length, and
Content-Disposition headers.

## Community

### GET /characters/{characterId}/community — Read character kudos and comments

Returns kudos totals and options, paged comments, and whether the linked viewer
may interact.

Use it for: showing the DataCat community thread beside a character in another
client.

- **Scope:** `community:read`
- **Authentication:** Client ID; linked bearer token optional
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `characterId` | path | UUID | Yes | The stable DataCat character identifier. |
| `limit` | query | integer 1…100 | No | Maximum reply rows. |
| `offset` | query | integer | No | Reply offset. |

Response example:

```json
{
  "success": true,
  "community": {
    "characterId": "UUID",
    "kudos": {
      "total": 4,
      "gifts": [{ "key": "fire", "label": "Fire", "emoji": "🔥", "count": 4 }],
      "options": [{ "key": "fire", "label": "Fire", "emoji": "🔥", "description": "..." }]
    },
    "comments": {
      "total": 2,
      "items": [{ "id": "UUID", "body": "Comment", "author": { "username": "cat", "avatarUrl": null }, "createdAt": "ISO-8601", "mine": false }],
      "paging": Paging
    },
    "canInteract": false
  }
}
```

### POST /characters/{characterId}/community/kudos — Give a character kudos

Creates one kudos reply using a gift key advertised by the community read
response.

Use it for: letting a signed-in DataCat user react to a character without leaving
the client.

- **Scope:** `community:write`
- **Authentication:** Client ID plus linked logged-in bearer token
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `characterId` | path | UUID | Yes | The stable DataCat character identifier. |
| `giftKey` | JSON body | string ≤40 chars | No | Gift key; defaults to `kudos`. |

Request example:

```bash
curl -X POST 'https://datacat.run/api/client/v1/characters/CHARACTER_UUID/community/kudos' \
  -H 'X-Datacat-Client-Id: YOUR_CLIENT_ID' \
  -H 'Authorization: Bearer dcv1_LINKED_ACCOUNT_TOKEN' \
  -H 'X-Datacat-Installation-Id: YOUR_INSTALLATION_ID' \
  -H 'Content-Type: application/json' \
  --data '{"giftKey":"fire"}'
```

Response example:

```json
{
  "success": true,
  "community": Community,
  "replyId": "UUID",
  "credits": { "balance": 99 }
}
```

### POST /characters/{characterId}/community/comments — Post a character comment

Creates a plain community comment and returns the refreshed thread.

Use it for: letting a signed-in user join the discussion from an approved
integration.

- **Scope:** `community:write`
- **Authentication:** Client ID plus linked logged-in bearer token
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `characterId` | path | UUID | Yes | The stable DataCat character identifier. |
| `body` | JSON body | string 1…4000 chars | Yes | Comment text. |

Request example:

```json
{
  "body": "A useful comment."
}
```

Response example:

```json
{
  "success": true,
  "community": Community,
  "replyId": "UUID",
  "credits": { "balance": 99 }
}
```

## Account linking

### POST /account-links — Start account linking

Creates a short-lived device authorization request for one client installation.

Use it for: allowing a desktop app, extension, or device to ask the user to
connect their DataCat account safely in the browser.

- **Scope:** `account:link`
- **Authentication:** Client ID
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `installationId` | JSON body or header | string 16…160 chars | Yes | Stable, non-secret ID for this client installation. |
| `clientName` | JSON body or `X-Datacat-Client` | string | No | Human-readable client name shown to the user. |
| `clientVersion` | JSON body | string | No | Installed client version. |

Request example:

```json
{
  "installationId": "desktop-installation-9bca7b31",
  "clientName": "My Client",
  "clientVersion": "1.2.0"
}
```

Response example:

```json
{
  "success": true,
  "linkId": "UUID",
  "deviceCode": "secret device code",
  "userCode": "ABCD-EFGH",
  "authorizationUri": "https://datacat.run/client-link",
  "authorizationUriComplete": "https://datacat.run/client-link?code=...",
  "expiresIn": 600,
  "interval": 3
}
```

### POST /account-links/{linkId}/token — Exchange an approved link

Polls an account-link request and returns a bearer token after the user approves
it.

Use it for: finishing the device flow and storing the linked installation token
for later account-aware requests.

- **Scope:** `account:link`
- **Authentication:** Client ID
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `linkId` | path | UUID | Yes | Link ID returned when the flow started. |
| `deviceCode` | JSON body | string | Yes | Secret device code returned with the link ID. |
| `installationId` | JSON body or header | string | Yes | Must match the installation that created the link. |

Response example:

```json
{
  "success": true,
  "accessToken": "dcv1_...",
  "tokenType": "Bearer",
  "scopes": ["characters:read", "account:link"],
  "expiresAt": "ISO-8601 timestamp",
  "accountState": "logged_in | linked_anonymous",
  "account": { "uuid": "UUID", "username": "cat", "displayName": "Cat", "userType": "user" }
}
```

### GET /account — Read the linked account

Returns the account and client metadata represented by the current bearer token.

Use it for: showing who is connected and which scopes and expiry apply to the
installation.

- **Scope:** Linked token scopes
- **Authentication:** Bearer token required
- **Returns:** application/json

Request parameters: no path, query, or body parameters.

Response example:

```json
{
  "success": true,
  "accountState": "logged_in",
  "account": { "uuid": "UUID", "username": "cat", "displayName": "Cat", "userType": "user" },
  "client": { "name": "My Client", "version": "1.2.0", "scopes": ["characters:read"], "clientId": "my_client", "expiresAt": "ISO-8601" }
}
```

### GET /account/status — Check account and rate-limit status

Returns the current linkage state, installation binding, and anonymous or
logged-in rate tier.

Use it for: lightweight connection checks and explaining whether signing in will
increase account-aware limits.

- **Scope:** `account:link`
- **Authentication:** Client ID; linked bearer token optional
- **Returns:** application/json

Request parameters: no path, query, or body parameters.

Response example:

```json
{
  "success": true,
  "accountState": "unlinked | linked_anonymous | logged_in",
  "account": null,
  "installation": { "boundToAccountToken": false, "linkageKind": null },
  "rateLimit": { "tier": "anonymous", "multiplier": 1, "discoveryMultiplier": 1, "linkedAccountMultiplier": 4 },
  "securityCheck": { "independentOfAccount": true, "requiredForProtectedTransfers": true }
}
```

### DELETE /account — Revoke the linked token

Revokes the bearer token used for the request and returns no response body.

Use it for: a Disconnect DataCat action that invalidates credentials server-side
instead of only deleting local storage.

- **Scope:** Linked token scopes
- **Authentication:** Bearer token required
- **Returns:** 204 No Content

Request parameters: no path, query, or body parameters.

Response example: HTTP 204 with an empty body.

## Human verification

### POST /verifications — Start a file-transfer verification

Creates a hosted human verification challenge bound to the client installation.

Use it for: obtaining the short-lived lease required before downloading card JSON
or archived images.

- **Scope:** `cards:read`
- **Authentication:** Client ID; bearer token optional
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `installationId` | JSON body or header | string 16…160 chars | Yes | Stable client installation ID. |
| `clientName` | JSON body or `X-Datacat-Client` | string | No | Name shown on the verification page. |
| `clientVersion` | JSON body | string | No | Installed client version. |
| `action` | JSON body | `character_transfer` | No | Verification purpose; currently `character_transfer`. |

Response example:

```json
{
  "success": true,
  "verificationId": "UUID",
  "deviceCode": "secret device code",
  "verificationUri": "https://datacat.run/client-verify",
  "verificationUriComplete": "https://datacat.run/client-verify?id=...",
  "expiresIn": 600,
  "interval": 3,
  "action": "character_transfer"
}
```

### GET /verifications/{verificationId} — Read verification status

Returns the public state and hosted challenge metadata for a verification
request.

Use it for: rendering or polling the hosted verification page while the challenge
is pending.

- **Scope:** Public challenge state
- **Authentication:** None
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `verificationId` | path | UUID | Yes | Verification ID returned by the create call. |

Response example:

```json
{
  "success": true,
  "verification": {
    "verificationId": "UUID",
    "status": "pending | verified | exchanged",
    "action": "character_transfer",
    "client": { "name": "My Client", "version": "1.2.0" },
    "turnstile": { "siteKey": "...", "action": "...", "cData": "..." }
  },
  "maxUniqueCharacters": 20
}
```

### POST /verifications/{verificationId}/complete — Complete the hosted challenge

Validates a Turnstile response and marks the verification request as verified.

Use it for: the DataCat-hosted verification page; third-party clients normally
open `verificationUriComplete` instead of calling this directly.

- **Scope:** Hosted verification
- **Authentication:** Turnstile response; Client ID optional
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `verificationId` | path | UUID | Yes | Verification ID. |
| `turnstileToken` | JSON body | string | Yes | Token produced by the hosted Turnstile widget. |

Response example:

```json
{
  "success": true,
  "verification": { "verificationId": "UUID", "status": "verified", "verifiedAt": "ISO-8601 timestamp" }
}
```

### POST /verifications/{verificationId}/token — Exchange verification for a lease

Exchanges a verified device challenge for the lease header used by protected
transfer endpoints.

Use it for: finishing the verification flow before calling `/card` or `/avatar`
for one or more characters.

- **Scope:** `cards:read`
- **Authentication:** Client ID; bearer token optional
- **Returns:** application/json

| Name | In | Type | Required | Description |
|---|---|---|---|---|
| `verificationId` | path | UUID | Yes | Verification ID. |
| `deviceCode` | JSON body | string | Yes | Secret returned by the create call. |
| `installationId` | JSON body or header | string | Yes | Must match the installation that created the challenge. |

Response example:

```json
{
  "success": true,
  "leaseToken": "dcv1v_...",
  "tokenType": "DataCat-Verification",
  "leaseHeader": "X-Datacat-Verification-Lease",
  "action": "character_transfer",
  "expiresAt": "ISO-8601 timestamp",
  "maxUniqueCharacters": 20
}
```

## Hosted and first-party routes

These complete browser-owned flows. Most integrations should open the supplied
hosted URL rather than call them directly.

| Method and path | Purpose | Who calls it |
|---|---|---|
| POST `/account-links/approve` | Approves a user code with a same-site DataCat session. | The hosted `/client-link` page. |
| POST `/account-links/{linkId}/browser-session` | Converts an approved link into a DataCat browser session. | Authorized first-party same-origin clients only. |
| GET `/client-link` | Hosts the account-link approval screen. | The user's browser. |
| GET `/client-verify` | Hosts the transfer verification screen. | The user's browser. |

## Errors, pagination, and rate limits

JSON errors pair an HTTP status with a stable error code and a human-readable
message. A protected transfer may include verification instructions. Binary
endpoints return the same JSON error format when they fail.

Error response:

```json
{
  "success": false,
  "error": "MACHINE_READABLE_CODE",
  "message": "Human-readable explanation",
  "accountState": "unlinked | linked_anonymous | logged_in",
  "verificationRequired": true,
  "verification": {
    "createPath": "/api/client/v1/verifications",
    "leaseHeader": "X-Datacat-Verification-Lease",
    "action": "character_transfer"
  }
}
```

| Status | Meaning |
|---|---|
| 400 | Invalid path, query, header, or JSON body. |
| 401 | Bearer token missing, invalid, expired, or not linked to a logged-in account. |
| 403 | Client or token lacks the required approved scope. |
| 404 | Character, creator, link, or challenge is unavailable. |
| 409 | A link or verification flow is not in the required state. |
| 410 | A short-lived link or verification challenge expired. |
| 429 | Rate limit reached. Wait for `Retry-After` seconds. |

List responses use `paging.hasMore` and `paging.nextOffset`. Treat `nextOffset`
as the only authoritative next page. Rate responses expose
`X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`,
`X-RateLimit-Scope`, and `X-RateLimit-Tier`.

---

## OpenAPI security-by-endpoint (from the spec)

For quick reference, which credentials each operation requires:

| Method | Path | Security |
|---|---|---|
| GET | `/capabilities` | public (none) |
| GET | `/characters` | Client ID |
| GET | `/fresh` | Client ID |
| GET | `/tags` | Client ID |
| GET | `/creators/{creatorRef}/bootstrap` | Client ID |
| GET | `/creators/{creatorRef}/characters` | Client ID |
| GET | `/characters/{characterId}` | Client ID |
| GET | `/characters/{characterId}/avatar-preview` | public (none) |
| GET | `/characters/{characterId}/card` | Client ID + VerificationLease, or Client ID + Bearer + VerificationLease |
| GET | `/characters/{characterId}/avatar` | Client ID + VerificationLease, or Client ID + Bearer + VerificationLease |
| GET | `/characters/{characterId}/community` | Client ID |
| POST | `/characters/{characterId}/community/kudos` | Client ID + Bearer + InstallationId |
| POST | `/characters/{characterId}/community/comments` | Client ID + Bearer + InstallationId |
| POST | `/account-links` | Client ID |
| POST | `/account-links/approve` | public (none) |
| POST | `/account-links/{linkId}/token` | Client ID |
| POST | `/account-links/{linkId}/browser-session` | Client ID |
| GET | `/account` | Bearer |
| DELETE | `/account` | Bearer |
| GET | `/account/status` | Client ID |
| POST | `/verifications` | Client ID |
| GET | `/verifications/{verificationId}` | public (none) |
| POST | `/verifications/{verificationId}/complete` | public (none) |
| POST | `/verifications/{verificationId}/token` | Client ID |