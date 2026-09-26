# Android Chat Usability and Accessibility

## How can the mobile chat be easier to operate for more people?

### Takeaway
The chat already has helpful foundations—clear Indonesian labels on most composer icons, a visible cancel button during generation, a one-line activity status, and message-level source chips. The next step is to make frequent actions reliably tappable, ensure TalkBack can understand the conversation without reading every streamed token, and preserve a clear route through long answers and attachments.

### Cited Findings
- Android recommends a minimum 48 × 48 dp touch target for interactive elements, including padding around a smaller visual icon. Larger targets can improve usability further. [Android accessibility for Views](https://developer.android.com/guide/topics/ui/accessibility/views/apps-views); [Compose accessibility codelab](https://developer.android.com/codelabs/jetpack-compose-accessibility)
- Android guidance says not to make gestures the only way to complete an action; provide an accessible action/control as an alternative. [Android mobile accessibility](https://developer.android.com/design/ui/mobile/guides/foundations/accessibility)
- Android semantics communicate a component’s meaning to assistive technologies. Icon-only controls need a localized textual description, while decorative icons should not add redundant spoken content. [Compose accessibility API defaults](https://developer.android.com/develop/ui/compose/accessibility/api-defaults); [Compose semantics](https://developer.android.com/develop/ui/compose/accessibility/semantics)
- Android recommends marking actual section headings as headings for direct screen-reader navigation, and using polite live regions for important changes; frequently changing content should not be a live region because it can overwhelm users. [Compose semantics](https://developer.android.com/develop/ui/compose/accessibility/semantics)
- WCAG 2.2 AA’s web-content minimum target size is 24 × 24 CSS px, with exceptions; its accompanying rationale says larger targets help touchscreen users and people with motor limitations. This is a web standard, not a substitute for Android’s 48 dp native recommendation. [WCAG 2.2, SC 2.5.8](https://www.w3.org/TR/wcag/#target-size-minimum); [W3C understanding SC 2.5.8](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum)
- Android recommends adjustable scalable text, at least 4.5:1 contrast for text, and 3:1 contrast for non-text components/icons; it also recommends using more than color alone to identify links. [Android mobile accessibility](https://developer.android.com/design/ui/mobile/guides/foundations/accessibility) (last updated 2023-05-08)
- The current Wangsa chat uses icon buttons for menu, new chat, attachment, mic, send, and stop; several have tooltips, but the visible conversation has no date/time separation or explicit sender labels in the widget source reviewed. Tool activity uses a `Semantics(liveRegion: true)` around its status, while the streaming answer itself is rendered as changing Markdown. [Wangsa `chat_page.dart`](../../apps/mobile/lib/chat/view/chat_page.dart); [Wangsa `thinking_indicator.dart`](../../apps/mobile/lib/chat/view/widgets/thinking_indicator.dart); [Wangsa `message_bubble.dart`](../../apps/mobile/lib/chat/view/message_bubble.dart)

### Inferences
- **P1 — Audit hit areas and labels.** Keep visual icon sizes compact if desired, but guarantee at least 48 dp hit regions for all composer and message actions. Add accessible labels that explain current state (“Stop generating”, “Start voice input”, “Remove attached image”) and ensure chips/source links are individually discoverable. Tooltips alone may not provide the best TalkBack experience in every context.
- **P1 — Make the transcript navigable.** Expose user/assistant turns, source groups, headings, and tool activity with a predictable TalkBack traversal order. Avoid one giant semantic node for a whole response. For long answers, mark Markdown headings semantically and make copy/share/read-aloud controls reachable after the answer.
- **P1 — Throttle streaming announcements.** Keep visual token streaming, but announce only meaningful milestones (e.g. “Wangsa is searching the web”, “Answer started”, “Answer complete”, “Could not connect”), not each token or rapidly changing activity. Current activity is already a live region, so verify that transitions do not produce repeated or interruptive TalkBack announcements.
- **P2 — Give the user a non-gesture path.** If swipe actions are later added for copying, replying, or deleting, also expose them through visible controls or an accessible actions menu.
- **P2 — Test with actual assistive settings.** Use TalkBack and Android Accessibility Scanner on a small phone and a large-text setting. Inspect focus order, voice labels, touch target bounds, contrast, scalable text, and whether focus remains sensible after sending/canceling. Android recommends scalable type, 4.5:1 text contrast, and 3:1 non-text contrast; the exact experience still needs device testing.

### Gaps
- I did not inspect all widgets (for example source chips, image gallery, voice overlay, and every model/settings sheet), so this is not a full accessibility audit.
- Android’s 48 dp target advice comes from Android developer guidance; this code is Flutter, and Flutter-specific widget defaults/semantics should be checked during implementation rather than assumed to match Compose behavior.

## How should the composer and keyboard behave?

### Takeaway
The composer should remain reachable and predictable as the keyboard opens, text grows, and the user scrolls. Keep one obvious primary action at a time, support keyboard submit sensibly, and do not surprise the user by moving their reading position while they are reviewing older messages.

### Cited Findings
- Android’s keyboard/IME guidance uses insets to move content with the keyboard and keep controls visible, and describes animated transitions rather than abrupt jumps. [Android IME animations](https://developer.android.com/develop/ui/compose/system/keyboard-animations); [Android edge-to-edge setup](https://developer.android.com/develop/ui/compose/system/setup-e2e)
- Android’s `TextField` API supports multiline fields, line limits, scroll behavior, and explicit keyboard actions. [Material 3 TextField API](https://developer.android.com/reference/kotlin/androidx/compose/material3/TextField.composable)
- Android’s large-screen guidance recommends testing keyboard navigation and common hardware-keyboard actions; Enter-to-send is called out as an app-specific chat behavior that developers may need to handle. [Android input compatibility](https://developer.android.com/develop/ui/compose/touch-input/input-compatibility-on-large-screens)
- Wangsa’s composer expands from one to four lines, sends on submit, and disables text entry while a response is in progress. The page scrolls to the latest turn on keyboard appearance; while streaming, it follows output only when already within 160 px of the bottom. [Wangsa `chat_page.dart`](../../apps/mobile/lib/chat/view/chat_page.dart)

### Inferences
- **P1 — Preserve a clear keyboard contract.** On mobile, the keyboard action should send only when that is the expected behavior; consider a newline-friendly multiline composer with the send button as the unambiguous primary action. On hardware keyboards/tablets, support and document Enter-to-send plus a modified Enter for newline if feasible.
- **P1 — Test keyboard insets and small screens.** Verify that the composer, attachment preview, selected-tool chips, and latest answer remain visible on short screens, landscape, split-screen, and with both gesture and three-button navigation. Insets guidance supports this as a platform expectation; inspect the current Flutter scaffold and Android window behavior rather than copying Compose APIs literally.
- **P1 — Make scroll-follow state explicit.** Keep auto-following only while the user is near the bottom (the current streaming behavior already approximates this). When the user scrolls up, show a small “Jump to latest” affordance and avoid snapping them back because a tool status or stream event changed.
- **P2 — Preserve draft and context.** Keep typed text and attachments intact after a failed request or cancel; provide a visible way to resume editing. During generation, consider whether users should be able to draft the next message, even if sending remains queued/disabled.
- **P2 — Keep composer growth bounded.** The existing four-line cap is sensible; verify that longer drafts remain easy to edit by scrolling within the field and that its send control stays visible.

### Gaps
- Android’s cited implementation guidance is written for Compose/Views, not Flutter. It supports interaction principles, but does not determine which Flutter `Scaffold`/inset configuration Wangsa currently uses.
- No device measurements were taken for keyboard occlusion, text-scale behavior, or one-handed reach.

## How should progress, errors, and recovery be communicated?

### Takeaway
A user should know that a request was received, what the agent is doing, whether the task is still active, and how to recover from failure. Communicate real progress and controls, but do not imply a percentage or completion estimate when the system cannot know one.

### Cited Findings
- Android describes progress indicators as status for loading, upload, or long processing. Determinate indicators should be used only when actual progress is known; otherwise use indeterminate status. [Android progress indicators](https://developer.android.com/develop/ui/compose/quick-guides/content/create-progress-indicator)
- Android’s current design guidance similarly says an indeterminate indicator fits unknown durations, warns against false progress, and advises against overusing indicators. The cited page is for AI Glasses, so treat the core progress principle as corroboration rather than mobile-specific component sizing. [Android progress indicators for AI Glasses](https://developer.android.com/design/ui/ai-glasses/guides/components/progress)
- Android accessibility documentation says important status changes can be exposed with polite live regions, but rapidly updated progress content should not be announced continuously. [Android accessibility node live region API](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo); [Compose semantics](https://developer.android.com/develop/ui/compose/accessibility/semantics)
- Wangsa already shows mapped tool status while the assistant is waiting/streaming, records completed tool calls in the message, exposes source chips after a complete answer, and provides a stop action during generation. The failed chat notice presents an error title and detail; the bloc also stores a one-turn `errorMessage`. [Wangsa `thinking_indicator.dart`](../../apps/mobile/lib/chat/view/widgets/thinking_indicator.dart); [Wangsa `tool_call_card.dart`](../../apps/mobile/lib/chat/view/widgets/tool_call_card.dart); [Wangsa `message_bubble.dart`](../../apps/mobile/lib/chat/view/message_bubble.dart); [Wangsa `chat_notice.dart`](../../apps/mobile/lib/chat/view/widgets/chat_notice.dart); [Wangsa `chat_state.dart`](../../apps/mobile/lib/chat/bloc/chat_state.dart)

### Inferences
- **P1 — Use a compact, staged activity timeline.** Keep the current minimal status near the in-progress answer, but show distinct states such as “Menghubungkan”, “Mencari web”, “Membuka halaman”, “Menyusun jawaban”, “Selesai”, and “Gagal”. Only show stages backed by backend events; do not invent intermediate activity or pretend a percentage is meaningful.
- **P1 — Make stop and retry consequences clear.** Retain the stop control, clarify whether partial output is preserved, and make recoverable errors actionable beside the failed turn (“Coba lagi”, “Periksa koneksi”, or “Atur model”, depending on cause). Keep the original prompt available so retry does not require retyping.
- **P1 — Distinguish source provenance from tool usage.** Tool badges describe what Wangsa did; source chips should identify material used in the final response. Keep source links tappable with readable domain/title labels and expose them to screen readers as sources for that answer.
- **P2 — Add a delayed, low-noise waiting hint for long tasks.** The request begins with the current activity label; if it takes noticeably longer, offer a factual hint such as “Ini bisa memerlukan waktu” and keep Stop visible. Avoid an invented ETA or percentage without reliable telemetry.
- **P2 — Make terminal states explicit.** On success, provide a subtle completion state and reveal citations/actions; on failure, show cause and one primary next step. Use one nonintrusive polite announcement for important state transitions, not a live region around token-by-token text.

### Gaps
- The Android sources do not prescribe a canonical AI-chat activity timeline or retry wording. The timeline and specific labels above are product recommendations inferred from Android progress/accessibility principles and Wangsa’s existing event model.
- The exact failure taxonomy exposed by the backend was not reviewed here, so error-specific recovery actions need mapping to actual API/network/auth/model errors before implementation.
