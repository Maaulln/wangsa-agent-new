# Conversational AI Chat UX

## How should Wangsa communicate progress and tool activity?

### Takeaway
Wangsa already exposes a short live activity label, completed tool cards, and a stop control. The next step is to make progress legible and truthful: show each meaningful step in plain language, signal unusually long waits, and distinguish tool outcomes without dumping internal logs into the conversation.

### Cited Findings
- Nielsen Norman Group's usability study of customer-service chat found that typing/progress messages help users wait more patiently; when a reply takes longer, users should be told that the agent is still working. Conflicting or vague status wording can make users unsure whether to wait or act. [NN/G: The User Experience of Customer-Service Chat](https://www.nngroup.com/articles/chat-ux/)
- Microsoft's evidence-based Human-AI Interaction guidelines cover initial use, interaction, system errors, and changes over time; they are a synthesis of 20+ years of research and were introduced in a CHI paper. [Microsoft HAX Toolkit](https://www.microsoft.com/en-us/haxtoolkit/ai-guidelines/); [CHI paper](https://doi.org/10.1145/3290605.3300233)
- A 2025 study introducing a visual Conversation Progress Guide reported improved self-efficacy measures compared with a conventional conversational AI interface. The available abstract supports progress feedback as a promising pattern, but does not establish one universally best layout. [Conversation Progress Guide](https://arxiv.org/abs/2501.12001)

### Inferences
- Keep the current compact activity row, but present a small expandable activity timeline for multi-step work: “Mencari di web” → “Membuka 3 halaman” → “Menyusun jawaban”. Use user-facing verbs and avoid exposing raw tool names/arguments by default. This builds on existing `ThinkingIndicator` and `ToolCallCard` rather than adding another status surface.
- Add a calm elapsed-time / “masih bekerja” message only after a meaningful delay, and update it when the phase changes. Avoid fake percentages because tool/model work has no reliable determinate completion percentage.
- Give every step a clear state (sedang berjalan, selesai, gagal), including distinct failed/cancelled states. The existing cards show an error icon for failed and a check icon for all other states, so the visual treatment should be more explicit for in-progress and cancellation.
- Preserve Wangsa's existing Stop control. On stop, tell users the response was stopped and retain any partial answer with a clear “lanjutan terhenti” state, rather than making an incomplete answer look final.

### Gaps
- There is no strong public study directly comparing step-by-step tool timelines with a single compact status line for mobile AI agents. Validate the proposed disclosure level with Wangsa users.
- Existing `ToolCallCard` expansion exposes a tool preview, but it is unclear whether this preview is sanitized and useful to ordinary users; assess it before promoting technical details.

## How should sources and answer confidence be presented?

### Takeaway
Source chips can help users orient themselves, but trust depends on citation quality and the source actually supporting the answer. Show a small, readable set of relevant page-level sources and preserve easy verification; do not treat a source count or domain icon as proof of correctness.

### Cited Findings
- In a live QA experiment, answers with citations received higher self-reported trust than answers with no citations; one citation and five citations did not differ significantly. The paper also reports that random citations reduced trustworthiness when inspected, so citation presence alone is not enough. [AAAI: Citations and Trust in LLM Generated Responses](https://ojs.aaai.org/index.php/AAAI/article/view/34550)
- NN/G found that chat users value specific, detailed answers and that the written transcript is useful for referring back to conversation details later. [NN/G: The User Experience of Customer-Service Chat](https://www.nngroup.com/articles/chat-ux/)
- A recent eye-tracking paper compares source-attribution layouts, but cautions that further research is needed to test whether verification-friendly source displays help users detect unsupported citations across populations and topics. [Source Attribution Visualization Study](https://pmc.ncbi.nlm.nih.gov/articles/PMC13513764/)

### Inferences
- Wangsa currently extracts structured sources (up to five) or markdown links and displays tappable chips. Prefer concise domain/page labels, open the exact source URL, and expose more sources in a bottom sheet or “Lihat semua” when the list is long.
- Where backend data supports it, attach a source to the relevant claim (inline numbered/citation markers that open the matching source). If claim-level mapping is unavailable, label the section “Sumber yang digunakan” and avoid implying every line is individually verified by every chip.
- Show source date/domain only when known and meaningful (e.g. web result freshness). Clearly distinguish web citations from uploaded-file references and general model knowledge.
- Avoid confidence percentages unless they are calibrated and validated. A plain-language caveat such as “Saya belum bisa memastikan bagian ini” is more honest when the answer is uncertain than an arbitrary score.

### Gaps
- The AAAI citation study was a web QA experiment, not a mobile-specific evaluation; it supports citation availability and relevance, not Wangsa's exact chip style.
- No cited source establishes that favicon/domain-only chips outperform textual page titles on small screens. Treat this as a design hypothesis to test.

## How should Wangsa support control, errors, and conversational flow?

### Takeaway
Make the agent's abilities and state understandable, allow users to interrupt or recover without losing their message/context, and use contextual controls instead of forcing users to learn commands. These principles are particularly relevant because Wangsa already has capability toggles, session history, follow-up chips, and Stop, while its failed-send message is currently a non-actionable banner.

### Cited Findings
- Microsoft's Human-AI Interaction guidelines organize design practices around what users need at first use, while interacting, when the AI is wrong, and over time. The underlying research emphasizes comprehensible capabilities and graceful management of AI failures. [Microsoft HAX Toolkit](https://www.microsoft.com/en-us/haxtoolkit/ai-guidelines/); [Microsoft Research summary](https://www.microsoft.com/en-us/research/articles/how-to-build-effective-human-ai-interaction-considerations-for-machine-learning-and-software-engineering/)
- NN/G recommends preserving conversation context through interruptions, giving people control over whether to continue, and avoiding asking users to repeat information already provided. It also says users can better calibrate expectations when told upfront they are interacting with a bot. [NN/G: The User Experience of Customer-Service Chat](https://www.nngroup.com/articles/chat-ux/)
- Google's conversation-design guidance says conversational systems should attend to dialogue context, keep prompts relevant and brief, and recover from recognition errors with a simple reprompt rather than a robotic error lecture. [Google Conversation Design](https://design.google/library/speaking-the-same-language-vui)

### Inferences
- Make failure banners actionable in place: “Kirim ulang” / “Salin pesan”, retain the user's draft and attachments after a failed send, and explain the likely next step in plain language. The current inline error text does not expose a retry action.
- Keep the existing ability selection but make its active state persistently visible and easy to inspect before sending; explain briefly what web search/image analysis will do and whether the setting applies only to a new chat (the current picker locks after conversation starts).
- Make the current static follow-up chips respond to the answer context (when feasible), limit them to a few useful actions, and let the composer remain the obvious primary way to continue. Current generic chips (“Jelaskan lebih lanjut”, “Buat ringkasan”) are helpful but may be irrelevant to some replies.
- Distinguish user, assistant, and system/error events accessibly, and ensure controls remain understandable with screen readers, larger system text, and comfortable touch targets. This is especially important for the compact icon row; unavailable thumbs-up/down actions should not appear as active controls.
- Treat technical details as progressive disclosure: ordinary users first see what Wangsa is doing and why; interested users can expand into tool/provider/source details.

### Gaps
- The NN/G article concerns customer-service chat and its study used eight participants; its recommendations are useful patterns, not a direct evaluation of an autonomous personal AI agent.
- No evidence in these sources tells us which follow-up chips Indonesian Wangsa users find most useful; use short usability sessions and observe whether people notice activity, verify sources, recover from a simulated failure, and continue a task.
