# Invalid Mermaid

The preview should show an error state or fall back to a code block, but should not crash.

```mermaid
this is not valid mermaid syntax
  ???
```

```mermaid
sequenceDiagram
  participant A
  A->>B: missing participant B declaration might be ok in some parsers
  A-->>: malformed arrow line
```
