fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac setup_icloud

```sh
[bundle exec] fastlane mac setup_icloud
```

Set up iCloud capabilities in Apple Developer Portal

### mac regenerate_profiles

```sh
[bundle exec] fastlane mac regenerate_profiles
```

Regenerate provisioning profiles after iCloud setup

### mac full_setup

```sh
[bundle exec] fastlane mac full_setup
```

Full setup - creates everything needed for iCloud

----


## iOS

### ios setup_icloud_ios

```sh
[bundle exec] fastlane ios setup_icloud_ios
```

Set up iCloud for iOS target

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
