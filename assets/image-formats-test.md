# Image Format Test

This file exercises Fen's preview across the image formats GitHub's Markdown renderer commonly supports — PNG, JPEG, GIF, SVG, and WebP — both as local relative-path files and as remote HTTP(S) URLs. Use it to confirm the preview loads every combination correctly.

## Local images (relative path)

Local PNG:

![Local PNG](image-formats/local-sample.png "Local PNG")

Local JPEG:

![Local JPEG](image-formats/local-sample.jpg "Local JPEG")

Local GIF:

![Local GIF](image-formats/local-sample.gif "Local GIF")

Local SVG:

![Local SVG](image-formats/local-sample.svg "Local SVG")

Local WebP:

![Local WebP](image-formats/local-sample.webp "Local WebP")

## Remote images (HTTPS)

Remote PNG:

![Remote PNG](https://octodex.github.com/images/yaktocat.png "Remote PNG")

Remote JPEG:

![Remote JPEG](https://octodex.github.com/images/codercat.jpg "Remote JPEG")

Remote GIF:

![Remote GIF](https://upload.wikimedia.org/wikipedia/commons/2/2c/Rotating_earth_%28large%29.gif "Remote GIF")

Remote SVG:

![Remote SVG](https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/markdown.svg "Remote SVG")

Remote WebP:

![Remote WebP](https://www.gstatic.com/webp/gallery/1.webp "Remote WebP")

## Reference-style links

Reference-style syntax exercises the same code path through a different parse route.

![Reference local PNG][local-png]
![Reference remote PNG][remote-png]

[local-png]: image-formats/local-sample.png "Reference local PNG"
[remote-png]: https://octodex.github.com/images/original.png "Reference remote PNG"

## Linked image

A local image wrapped in a link, so clicking it opens the full remote asset.

[![Linked thumbnail](image-formats/local-sample.jpg "Click through")](https://octodex.github.com/images/original.png)
