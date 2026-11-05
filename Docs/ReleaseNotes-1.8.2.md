# DevŻbik 1.8.2

MySQL passwords can now be remembered in the local macOS Keychain. **Remember password in Keychain** is enabled by default: enter your password once and connect successfully, then DevŻbik fills it in when you reopen Databases or restart the app.

Passwords are stored separately for each local port and user. Failed connections do not overwrite saved credentials. Turning remembering off removes the selected account's saved password. Keychain errors are reported separately from MySQL connection errors, and a failed read can be retried.

Open **Settings → App updates**, check for version **1.8.2**, then choose **Install and restart** when the download is ready.
