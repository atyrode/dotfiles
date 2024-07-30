# Setup

## Addons

### Required

- [Sidebery](https://addons.mozilla.org/fr/firefox/addon/sidebery/)

### Optional

-

# Info

## about:config modifications (automatically set by [user.js](profile/user.js))

<!-- START_PREF_TABLE -->
| **Preference Name** | **Description** | **Updated value** | **Default value** |
|-|-|-|-|
| `devtools.chrome.enabled` | Enable developer tools for chrome and add-ons | `true` | `false` |
| `devtools.debugger.remote-enabled` | Enable remote debugging | `true` | `false` |
| `devtools.debugger.prompt-connection` | Disable the connection prompt for remote debugging | `false` | `true` |
| `toolkit.legacyUserProfileCustomizations.stylesheets` | Enable userChrome.css and userContent.css | `true` | `false` |
<!-- END_PREF_TABLE -->

# Dev

## [setup.sh](setup.sh)

This script naively assume you're on **MacOS**, it does, in order:

1. Copy the content of the [profile](profile) folder inside the Firefox profile "`arcfox`"

## [restart.sh](restart.sh)

This script naively assume you're on **MacOS**, it does, in order:

1. Install the Firefox dotfile config (using [setup.sh](setup.sh))
2. Kill any running Firefox process
3. Switch one desktop to the right
3. Run Firefox

This process is required to see changes made to the CSS.

## Developer Console

### - MacOS

`Cmd` + `Option` + `Shift` + `I`

### - Normal OS

`Ctrl` + `Alt` + `Shift` + `I`

# Trivia

## userChrome.css, devtools.chrome.enabled, etc...

In the context of web browsers and software development, “chrome” refers to the non-content part of the browser window.

It is not related to Google Chrome.

## Regexes

