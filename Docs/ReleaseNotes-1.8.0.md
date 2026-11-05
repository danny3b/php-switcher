# DevŻbik 1.8.0

The new **Databases** tab replaces a local MySQL database from an SQL export.

1. Connect to MySQL on `127.0.0.1` using its port, user, and password. MAMP and common Homebrew client locations are detected automatically.
2. Select the local database and a `.sql` table/data export from mysqldump or phpMyAdmin.
3. Choose **Replace database…**, type the database name, and confirm **Clear and import**.

A backup is enabled by default and must finish before clearing begins. The selected database is recreated with its original default character set and collation. Source database headers are omitted so the local name can differ from the exported name. Progress, cancellation, errors, and the completed backup are shown in the app.

System databases are protected, the server identity is checked again before clearing, and concurrent replacements of the same database are blocked. Passwords are not saved in preferences or passed in process arguments. Application quit and update installation wait until database operations finish or are cancelled.

This version accepts single-database **table/data dumps**. Views, routines, triggers, events, multiple databases, explicit database-qualified names, and unsupported SQL commands are rejected before clearing. Import is not transactional: a later MySQL error or cancellation can leave incomplete data; a completed backup remains available for recovery.

## Update

Open **Settings → App updates**, check for version **1.8.0**, then choose **Install and restart** when the download is ready.

For a new installation, download [DevZbik-1.8.0-arm64.dmg](https://github.com/danny3b/php-switcher/releases/download/v1.8.0/DevZbik-1.8.0-arm64.dmg).
