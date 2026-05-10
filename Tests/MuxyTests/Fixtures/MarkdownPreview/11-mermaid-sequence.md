# Mermaid sequence diagram

```mermaid
sequenceDiagram
  participant U as User
  participant A as App
  participant S as Server

  U->>A: Open preview
  A->>S: Fetch markdown assets
  S-->>A: 200 OK
  A-->>U: Rendered preview
```
