# On Air app icon

`on-air-app-icon-v4.png` is the approved master: a soft red radio microphone above the app's red wave, with transparent corners. Keep this original unchanged when producing platform sizes. The accompanying prompt records its image-generation provenance.

The macOS icon lives in `OnAir/Assets.xcassets/AppIcon.appiconset`. Xcode compiles it into the app's icon resources for Finder, Dock, and system dialogs. The menu-bar state symbol remains separate.

To regenerate the PNG representations from the repository root:

```sh
for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" design/on-air-app-icon-v4.png \
    --out "OnAir/Assets.xcassets/AppIcon.appiconset/icon-$size.png"
done
```

`Contents.json` maps these representations to the standard macOS 1× and 2× icon slots. Preserve the alpha channel and the existing padding; do not crop or redraw the approved artwork.
