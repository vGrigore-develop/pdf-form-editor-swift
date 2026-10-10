# App icon

`AppIcon.svg` is the 1024 px master (rounded square on a transparent canvas, 100 px margin). `AppIcon-small.svg` is the simplified variant used for the 16 and 32 px sizes.

`scripts/make-icon.sh` renders both with AppKit (`scripts/render-svg.swift`, which also adds the drop shadow) and builds `AppIcon.icns` with `iconutil`. The `.icns` is committed; `scripts/build-app.sh` copies it into the app bundle as the `CFBundleIconFile` fallback.

## Liquid Glass icon

`AppIcon.icon` is an Icon Composer document (open it in Icon Composer, bundled with Xcode 26 and later, to adjust it). It was written by hand from the master and holds the same artwork as separate flat layers in `AppIcon.icon/Assets/`, with no squircle, shadows or highlights baked in; the system draws those:

- background: the document fill, a teal gradient (#27A0A0 to #0A3A47), darker in Dark mode;
- `Voucher` group: `voucher.svg`, the cream stepped silhouette, glass;
- `Field` group: `field.svg` (the field box, glass) and `lines.svg` (the two text bars, flat, 50 % opacity);
- `Handle` group (front): `handle.svg`, the amber handle dot, glass with a coloured shadow.

The layer SVGs use the master's coordinates (`viewBox="100 100 824 824"`), so the artwork fills Icon Composer's 1024 px canvas in the same proportions as the master. Tinted and Clear appearances are derived by the system from the layers.

`scripts/make-liquid-icon.sh <out-dir>` compiles the document with `actool` into `Assets.car` (layered icon plus flattened renditions for older macOS). `scripts/build-app.sh` runs it when Xcode 26+ `actool` is available, copies `Assets.car` into the bundle and adds `CFBundleIconName = AppIcon` to the bundle's Info.plist; without it, the build still succeeds with the `.icns` only. The car (about 1.7 MB) is built, not committed.

To preview a rendition without the GUI, Icon Composer ships `ictool`:

```
"$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool" Resources/AppIcon/AppIcon.icon \
  --export-image --output-file preview.png --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
```

Renditions: `Default`, `Dark`, `TintedLight`, `TintedDark`, `ClearLight`, `ClearDark`.
