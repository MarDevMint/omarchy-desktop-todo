# Desktop TODO — Omarchy shell plugin

Sticky-note TODO cards pinned to your Omarchy desktop: above the wallpaper, below every window.

- Each card is a plain Markdown checklist in `~/.local/share/omarchy/todo/*.md`
- **Drag** any empty part of a card to move it; each card remembers its own position
- **Pastel colors** per card (right-click), or follow the active theme
- **Night mode**: pastels turn into deep tinted paper on dark themes and between 18:00 and 07:00
- Double-click a title to rename, `+` for a new list, copy a task's text with one click

## Install

```bash
git clone https://github.com/MarDevMint/omarchy-desktop-todo ~/.config/omarchy/plugins/m.todo
omarchy restart shell
```

Add `m.todo` to your shell plugins if it is not picked up automatically.

## IPC

```bash
omarchy-shell todo add "Buy milk"   # add to the first list
omarchy-shell todo toggle           # show / hide
omarchy-shell todo focus            # jump to the first input
```

## Card format

```markdown
# TODO
<!-- color: mint -->
- [ ] open task
- [x] finished task
```

Colors: `rose`, `peach`, `butter`, `mint`, `sky`, `lavender`, `stone` (or omit for the theme).

## License

MIT
