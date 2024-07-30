# Setup

## Addons

### Required

- [Sidebery](https://addons.mozilla.org/fr/firefox/addon/sidebery/)

### Optional

- 

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

## about:config

These parameters are set by the [user.js](profile/user.js) config file:

| **Preference Name**                      | **Description**                                                          | **Default Value** | **Desired Value** |
|------------------------------------------|--------------------------------------------------------------------------|-------------------|-------------------|
| `devtools.chrome.enabled`                | Enables developer tools for browser chrome and extensions.               | `false`           | `true`            |
| `devtools.debugger.remote-enabled`       | Allows remote debugging of Firefox itself.                               | `false`           | `true`            |
| `devtools.debugger.prompt-connection`    | Suppresses the confirmation prompt for remote debugging connections.     | `true`            | `false`           |


They enable access to the Developer Console of the Firefox App itself with:

### - MacOS

`Cmd` + `Option` + `Shift` + `I`

### - Normal OS

`Ctrl` + `Alt` + `Shift` + `I`

# Trivia

## userChrome.css, devtools.chrome.enabled, etc...

In the context of web browsers and software development, “chrome” refers to the non-content part of the browser window.

It is not related to Google Chrome.