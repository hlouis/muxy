# HTML block

Below is a raw HTML block. The native preview should match expected behavior (either render HTML, sanitize it, or show it as text) consistently.

<div class="callout">
  <p><strong>HTML content</strong> with <a href="https://example.com">a link</a>.</p>
  <ul>
    <li>HTML list item 1</li>
    <li>HTML list item 2</li>
  </ul>
</div>

<script>
// If scripts are stripped/sandboxed, this should not execute.
console.log('script tag in markdown fixture');
</script>

After HTML.
