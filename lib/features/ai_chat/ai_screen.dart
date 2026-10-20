import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/result.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../main.dart';
import 'ai_chat_repository.dart';

/// Chat against any OpenAI-compatible endpoint, with streaming.
class AiScreen extends StatefulWidget {
  const AiScreen({super.key});

  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  final List<ChatMessage> _messages = [];
  String _streaming = '';
  bool _sending = false;
  bool _configured = true;
  AppFailure? _failure;

  @override
  void initState() {
    super.initState();
    _checkConfigured();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _checkConfigured() async {
    final services = AppScope.of(context, dependOn: false);
    final endpoint = await services.settings.aiEndpoint();
    if (mounted) setState(() => _configured = endpoint.isConfigured);
  }

  void _newChat() {
    setState(() {
      _messages.clear();
      _streaming = '';
      _failure = null;
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;

    final services = AppScope.of(context, dependOn: false);
    _input.clear();

    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
      _sending = true;
      _streaming = '';
      _failure = null;
    });
    _scrollDown();

    final result = await services.ai.sendStream(
      List.of(_messages),
      onDelta: (delta) {
        if (!mounted) return;
        setState(() => _streaming += delta);
        _scrollDown();
      },
      onDone: () {},
    );

    if (!mounted) return;
    setState(() {
      _sending = false;
      if (result is Success) {
        _messages.add(result.dataOrNull!);
        _streaming = '';
      } else {
        _failure = result.errorOrNull;
      }
    });
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.aiTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: l10n.aiNewChat,
            onPressed: _newChat,
          ),
        ],
      ),
      body: !_configured
          ? EmptyState(
              title: l10n.aiNotConfigured,
              body: l10n.aiNotConfiguredBody,
              icon: Icons.smart_toy_outlined,
            )
          : Column(
              children: [
                Expanded(
                  child: _messages.isEmpty && _streaming.isEmpty
                      ? EmptyState(
                          title: l10n.aiTitle,
                          body: l10n.aiPlaceholder,
                          icon: Icons.smart_toy_outlined,
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(AppTheme.spaceMd),
                          itemCount:
                              _messages.length + (_streaming.isEmpty ? 0 : 1),
                          itemBuilder: (context, i) {
                            if (i < _messages.length) {
                              return _Bubble(message: _messages[i]);
                            }
                            return _Bubble(
                              message: ChatMessage(
                                role: 'assistant',
                                content: _streaming,
                              ),
                              pending: _sending,
                            );
                          },
                        ),
                ),
                if (_failure != null)
                  Container(
                    width: double.infinity,
                    color: scheme.errorContainer,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTheme.spaceMd,
                      vertical: AppTheme.spaceSm,
                    ),
                    child: Text(
                      l10n.errorFor(_failure!.kind.name),
                      style: text.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppTheme.spaceMd,
                      AppTheme.spaceSm,
                      AppTheme.spaceMd,
                      AppTheme.spaceMd,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _input,
                            minLines: 1,
                            maxLines: 5,
                            decoration:
                                InputDecoration(hintText: l10n.aiPlaceholder),
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        const SizedBox(width: AppTheme.spaceSm),
                        IconButton.filled(
                          icon: _sending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.send),
                          tooltip: l10n.aiSend,
                          onPressed: _sending ? null : _send,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, this.pending = false});

  final ChatMessage message;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final isUser = message.role == 'user';

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spaceMd,
          vertical: AppTheme.spaceSm + 2,
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        decoration: BoxDecoration(
          color: isUser ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(AppTheme.radiusMd),
            topRight: const Radius.circular(AppTheme.radiusMd),
            bottomLeft: Radius.circular(isUser ? AppTheme.radiusMd : 4),
            bottomRight: Radius.circular(isUser ? 4 : AppTheme.radiusMd),
          ),
        ),
        child: Text(
          message.content.isEmpty && pending ? '…' : message.content,
          style: text.bodyLarge?.copyWith(
            color: isUser ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}
