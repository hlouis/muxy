# Native Markdown Preview QA Checklist

Scope: manual QA for the native markdown preview migration. Use the fixture corpus under `Tests/MuxyTests/Fixtures/MarkdownPreview/`.

## Setup

- Open each fixture file and open the Markdown preview.
- Repeat with light and dark appearance (if supported).
- If the preview supports live updates, make a small edit and confirm the preview updates.

## Rendering correctness

For each fixture:

- Headings render with correct hierarchy and spacing.
- Lists render correctly (ordered, unordered, nested; tight vs loose).
- Blockquotes render correctly, including nested quotes and quote-contained lists.
- Tables render with alignment, inline formatting inside cells, and escaped pipes.
- Code blocks render with correct monospace styling and preserved whitespace.
- Syntax highlighting (if supported) matches the language fences and does not regress selection/copy.
- Links:
  - Autolinks and normal links are clickable.
  - Reference links resolve.
  - URLs with parentheses and fragments work.
- Images:
  - Images load when reachable.
  - Broken images fail gracefully (no crash, reasonable placeholder).
- Task lists show checked/unchecked states and nesting.

## Mermaid

- Valid Mermaid renders for:
  - Flowchart fixture
  - Sequence diagram fixture
- Invalid Mermaid fixture:
  - Does not crash/hang.
  - Shows a readable error state or degrades to code block rendering.

## Interaction and UX

- Scroll performance is smooth for the mixed/large fixture.
- Selection and copy/paste from preview preserves content (especially code blocks).
- If editor-preview sync exists:
  - Clicking in the preview scrolls/highlights the corresponding source region.
  - Scrolling the editor updates the preview anchor, and vice versa.
- Focus/keyboard:
  - Cmd+F (or search) works as expected.
  - Tab/arrow navigation does not trap focus.

## Security / sandboxing (HTML fixture)

- Raw HTML behavior is consistent with expected policy (render/sanitize/escape).
- Script tags do not execute.
- External loads (images/links) follow the app’s security and privacy expectations.

## Regression checks

- No console errors or repeated warnings during render.
- No memory growth or runaway CPU when switching fixtures repeatedly.
