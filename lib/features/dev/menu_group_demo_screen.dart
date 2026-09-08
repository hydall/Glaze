import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/menu_group.dart';

class MenuGroupDemoScreen extends StatefulWidget {
  const MenuGroupDemoScreen({super.key});

  @override
  State<MenuGroupDemoScreen> createState() => _MenuGroupDemoScreenState();
}

class _MenuGroupDemoScreenState extends State<MenuGroupDemoScreen> {
  // MenuSwitchItem state
  bool _switch1 = true;
  bool _switch2 = false;
  bool _switchWithHelp = true;

  // MenuRangeItem state
  double _temperature = 0.7;
  double _topP = 0.9;

  // MenuFieldItem state
  final _nameCtrl = TextEditingController(text: 'My OpenAI');
  final _endpointCtrl = TextEditingController(text: 'http://127.0.0.1:5000/v1');
  final _maxTokensCtrl = TextEditingController(text: '8000');

  // MenuSelectorItem state
  String _effort = 'Medium';

  bool _showKey = false;
  final _keyCtrl = TextEditingController(text: 'sk-abc123');

  @override
  void dispose() {
    _nameCtrl.dispose();
    _endpointCtrl.dispose();
    _maxTokensCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GlazeScaffold(
      title: 'menu_menu_group_demo'.tr(),
      onBack: () => Navigator.of(context).pop(),
      body: ListView(
        padding: const EdgeInsets.only(top: 16, bottom: 32),
        children: [
          // ── 1. Regular MenuGroup — navigation items ──────────────────────
          _SectionLabel('MenuGroup (default) — navigation'),
          MenuGroup(
            header: 'General',
            items: [
              MenuItem(
                icon: Icons.palette_outlined,
                label: 'Theme',
                value: 'Dark',
                onTap: () {},
              ),
              MenuItem(
                icon: Icons.language_outlined,
                label: 'Language',
                value: 'English',
                onTap: () {},
              ),
              MenuItem(
                icon: Icons.notifications_none_outlined,
                label: 'Notifications',
                trailing: const Icon(Icons.chevron_right, size: 18, color: Color(0xFF99A2AD)),
                onTap: () {},
              ),
            ],
          ),

          // ── 2. Regular MenuGroup — switches ──────────────────────────────
          _SectionLabel('MenuGroup (default) — switches'),
          MenuGroup(
            header: 'Interface',
            items: [
              MenuSwitchItem(
                label: 'Battery Saver UI',
                description: 'Reduces animations and blur effects',
                value: _switch1,
                onChanged: (v) => setState(() => _switch1 = v),
              ),
              MenuSwitchItem(
                label: 'Enter to Send',
                description: 'Press Enter to submit messages',
                value: _switch2,
                onChanged: (v) => setState(() => _switch2 = v),
              ),
            ],
          ),

          // ── 3. Regular MenuGroup — no header ─────────────────────────────
          _SectionLabel('MenuGroup (default) — no header'),
          MenuGroup(
            items: [
              MenuItem(
                icon: Icons.info_outline,
                label: 'About',
                onTap: () {},
              ),
              MenuItem(
                icon: Icons.logout,
                label: 'Sign Out',
                onTap: () {},
              ),
            ],
          ),

          // ── 4. MenuGroup with MenuSubHeader ───────────────────────────────
          _SectionLabel('MenuGroup (default) — with MenuSubHeader'),
          MenuGroup(
            header: 'UI Elements',
            items: [
              const MenuSubHeader('Background'),
              MenuItem(label: 'Color', value: '#1A1A1A', onTap: () {}),
              MenuItem(label: 'Opacity', value: '85%', onTap: () {}),
              const MenuSubHeader('Border'),
              MenuItem(label: 'Width', value: '1 px', onTap: () {}),
              MenuItem(label: 'Color', value: '#FFFFFF26', onTap: () {}),
            ],
          ),

          // ── 5. compact — text fields ──────────────────────────────────────
          _SectionLabel('MenuGroup (compact) — MenuFieldItem'),
          MenuGroup(
            compact: true,
            header: 'Connection',
            helpTerm: 'api',
            items: [
              MenuFieldItem(
                label: 'Config Name',
                controller: _nameCtrl,
                placeholder: 'My OpenAI',
              ),
              MenuFieldItem(
                label: 'Endpoint',
                controller: _endpointCtrl,
                placeholder: 'http://127.0.0.1:5000/v1',
              ),
              MenuFieldItem(
                label: 'API Key',
                helpTerm: 'apikey',
                controller: _keyCtrl,
                placeholder: 'sk-...',
                obscure: !_showKey,
                suffix: IconButton(
                  icon: Icon(
                    _showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ),
            ],
          ),

          // ── 6. compact — range sliders ────────────────────────────────────
          _SectionLabel('MenuGroup (compact) — MenuRangeItem'),
          MenuGroup(
            compact: true,
            header: 'Generation',
            helpTerm: 'guided',
            items: [
              MenuRangeItem(
                label: 'Temperature',
                value: _temperature,
                min: 0,
                max: 2,
                divisions: 200,
                onChanged: (v) => setState(() => _temperature = v),
              ),
              MenuRangeItem(
                label: 'Top P',
                value: _topP,
                min: 0,
                max: 1,
                divisions: 100,
                onChanged: (v) => setState(() => _topP = v),
              ),
            ],
          ),

          // ── 7. compact — switches with helpTerm ──────────────────────────
          _SectionLabel('MenuGroup (compact) — MenuSwitchItem + helpTerm'),
          MenuGroup(
            compact: true,
            header: 'Omit Parameters',
            items: [
              MenuSwitchItem(
                label: 'Omit Temperature',
                description: 'Do not send temperature in the request',
                value: _switchWithHelp,
                onChanged: (v) => setState(() => _switchWithHelp = v),
              ),
              MenuSwitchItem(
                label: 'Streaming',
                helpTerm: 'streaming',
                description: 'Receive tokens as they are generated',
                value: _switch1,
                onChanged: (v) => setState(() => _switch1 = v),
              ),
            ],
          ),

          // ── 8. compact — selector ─────────────────────────────────────────
          _SectionLabel('MenuGroup (compact) — MenuSelectorItem'),
          MenuGroup(
            compact: true,
            header: 'Reasoning',
            helpTerm: 'preset-reasoning',
            items: [
              MenuSwitchItem(
                label: 'Enable Reasoning',
                description: 'Use extended thinking for responses',
                value: _switch2,
                onChanged: (v) => setState(() => _switch2 = v),
              ),
              MenuSelectorItem(
                label: 'Reasoning Effort',
                currentValue: _effort,
                onTap: () => _pickEffort(),
              ),
            ],
          ),

          // ── 9. compact — mixed, no header ────────────────────────────────
          _SectionLabel('MenuGroup (compact) — mixed, no header'),
          MenuGroup(
            compact: true,
            items: [
              MenuFieldItem(
                label: 'Max Tokens',
                controller: _maxTokensCtrl,
                placeholder: '8000',
                keyboardType: TextInputType.number,
              ),
              MenuRangeItem(
                label: 'Temperature',
                value: _temperature,
                min: 0,
                max: 2,
                divisions: 200,
                onChanged: (v) => setState(() => _temperature = v),
              ),
              MenuSwitchItem(
                label: 'Stream',
                value: _switch1,
                onChanged: (v) => setState(() => _switch1 = v),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _pickEffort() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: ['Low', 'Medium', 'High', 'Auto'].map((e) {
            return ListTile(
              title: Text(e),
              trailing: e == _effort ? const Icon(Icons.check) : null,
              onTap: () {
                setState(() => _effort = e);
                Navigator.pop(context);
              },
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
