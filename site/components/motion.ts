export function isShortcut(event: KeyboardEvent): boolean {
  return event.metaKey && !event.shiftKey && !event.altKey && !event.ctrlKey && event.code === 'Space';
}
