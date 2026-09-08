export function syncCodeBlockMetadata(root) {
  // Formatter owns code block HTML; renderer only preserves the hook boundary.
  return root.querySelectorAll('.code-block-wrapper').length;
}
