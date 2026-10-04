# Launch Screen Assets

The current iOS launch screen is `ios/Runner/Base.lproj/LaunchScreen.storyboard`.
It contains only a white root view and does not reference the `LaunchImage`
asset set in this directory.

Replacing `LaunchImage.png`, `LaunchImage@2x.png`, or `LaunchImage@3x.png` alone
therefore has no effect on the launch screen. To show an image, update the
storyboard to include an image view that references `LaunchImage` (or configure
another launch-screen resource) as well as replacing the asset files.
