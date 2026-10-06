# Frontend provenance

The application views, presentation behavior, CSS, images, sounds, JavaScript
controllers and the unchanged benchmark HTTP client originate from
[37signals Campfire](https://github.com/basecamp/once-campfire), revision
`d2155e85a01b8439c32a3604ebb7f39fea1ace0f`, under the [MIT license](MIT-LICENSE).
The views and helpers have been adapted to independent Ruby and Erubi. Frequently
rendered message templates use direct HTML. The Roda application loads no Rails
Ruby libraries.

`frontend/` contains the editable application JavaScript. `bin/build_frontend`
fingerprints those files and updates `public/assets/.manifest.json`. The original
stylesheet, image, sound and vendor JavaScript artifacts are retained in
`public/assets/`; they were built from that reference checkout. No Rails asset
pipeline or Node process is needed to run or rebuild the application JavaScript.

The browser uses these standalone libraries from the original frontend:

| Library | License notice |
| --- | --- |
| Turbo and its stream client | [MIT](licenses/Turbo.txt) |
| Stimulus and its loader | [MIT](licenses/Stimulus.txt) |
| Action Cable JavaScript protocol client | [MIT](licenses/Action-Cable-JavaScript.txt) |
| Rails Request.js HTTP client | [MIT](licenses/Request-JS.txt) |
| Lexxy editor | [MIT](licenses/Lexxy.txt) |
| Lexical, included by Lexxy | [MIT](licenses/Lexical.txt) |
| Prism, included by Lexxy | [MIT](licenses/Prism.txt) |
| Marked, included by Lexxy | [MIT](licenses/Marked.txt) |
| DOMPurify 3.3.0, included by Lexxy | [Apache 2.0 or MPL 2.0](licenses/DOMPurify.txt) |
| highlight.js and language definitions | [BSD 3-Clause](licenses/Highlight-js.txt) |

Existing license comments in the JavaScript distributions are preserved. The
Action Cable name here refers to the browser wire-protocol client; the server
implementation is in `lib/campfire/realtime/` and uses `websocket-driver`.

The copied asset distribution also contains unused legacy [Trix](licenses/Trix.txt)
and [Rails browser asset](licenses/Rails-browser-assets.txt) files, including
Active Storage, Action Text and UJS JavaScript. They are retained as source
artifacts and are not imported by the application's JavaScript entry point.

Roda-specific changes to the original application JavaScript currently add an
explicit user ID to mention matching. This allows the editor to highlight a
mention even though avatar URLs use signed tokens. No frontend controls have
been removed for the benchmarks.
