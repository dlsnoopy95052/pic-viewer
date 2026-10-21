# Picture Viewer

A native macOS app for viewing the pictures in a folder, with light annotation and editing.

## Language

**Picture**:
The file the user is viewing, browsing, annotating or editing.
_Avoid_: Image, photo

**Capture**:
A Picture made by selecting an area of the screen with the global hot key; it opens in the viewer like any other Picture.
_Avoid_: Screenshot, snip

**Annotation**:
An editable mark drawn over a Picture that can be moved, resized, restyled or deleted until the Picture is flattened. Kinds: line, arrow, rectangle, circle, pen, text, Mosaic, Pasted layer.
_Avoid_: Mark, overlay, shape

**Mosaic**:
An Annotation that pixelates the area it covers, to hide sensitive content.
_Avoid_: Blur, redact

**Pasted layer**:
An Annotation holding a picture pasted from the clipboard, which can be moved, resized and rotated on top of the open Picture.
_Avoid_: Layer (on its own), sticker

**Flatten**:
Permanently merge all Annotations and any View rotation into the Picture's pixels, after which they can no longer be edited individually.
_Avoid_: Bake, commit, merge

**View rotation**:
A rotation that only changes how the Picture is displayed, without changing its pixels until the Picture is flattened.
_Avoid_: Rotate (as a pixel operation)

**Annotate**:
Add or change Annotations. Non-destructive until the Picture is flattened.

**Edit**:
Change the Picture's pixels directly: crop, flip, brightness, contrast, saturation. Starting an Edit flattens the Picture first.
_Avoid_: Adjust (as the general term)
