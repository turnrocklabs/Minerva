# Live document and view handles

DCR: `01a0822e03637156a0088563c41e00ac`.

`minerva_list_editors` exposes `document_id` and `view_id`. These opaque handles
identify live objects independently of tab titles. `minerva_doc_read` also returns
the canonical buffer's document handle. Document read/write/edit/save accept the
handles; panel-executed plugin tools receive the same generic locator support.

| Operation | Identity behavior |
| --- | --- |
| Paired text/render views | Same document handle, distinct view handles |
| Tab rename | Both handles remain valid |
| Rebinding the canonical buffer, including first Save-As | Document handle remains valid |
| Creating a different buffer, including Save-As that creates a copy | New document handle |
| Closing a view | Its view handle expires; other views remain valid |
| Disposing the document buffer | Its document handle expires |
| Reopen or session restore | Enumerate new handles; use file paths as durable locators |

A document-only text operation targets the shared buffer without selecting a view.
A plugin panel operation selects that plugin's unique view of the document. If
several matching views exist, it reports ambiguity and candidate handles. An
explicit view can disambiguate; a supplied document/view pair must agree. Handles
never fall back to similarly named tabs. Legacy name lookup refuses duplicate
titles. Path and name locators remain supported.

Save-As by handle requires a view when the editor must rebind. Saving an already
bound document needs only its document handle. Existing version guards still
protect concurrent edits; handles neither snapshot nor copy the source buffer.

The registry owns canonical buffers. IDs are session-scoped object handles, not a
second persistent document store or part of geometry cache keys. Generic buffer
attachment/change notifications carry the document handle so plugins can associate
evaluated output with its source without identifying documents by presentation names.
