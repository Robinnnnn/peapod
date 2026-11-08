# README system diagram

Generated with [Pele](https://pele.run/) using editable Mermaid block-diagram
syntax in `message-flow.mmd`. Light/dark SVG variants display as one diagram
through the root README's `<picture>` element.

```sh
npm ci --prefix docs/diagrams
npm run --prefix docs/diagrams render
```

Pele is pinned in this directory's lockfile and is documentation tooling only.
Update the source and regenerate both variants together; do not edit rendered
SVGs by hand. Accessibility title/description comments are embedded by the renderer.

The diagram combines encrypted message delivery, each person's private
Apple-account key synchronization, and the iPhone notification path. The main
message flow uses solid arrows; synchronization and notifications use dashed
arrows. Initial secure pairing is summarized in the README caption.
