# GitHub Backup Script

This script automates the process of backing up all the GitHub repositories  a specified user has access to including those that are part of an organization. It is designed with robustness in mind, providing mechanisms to handle network interruptions, large repositories, orphaned repositories, and more. The script uses **SSH** authentication to securely interact with GitHub and ensures data integrity by handling duplicates and potential repository name conflicts.

## Features
- **Backup for all repositories** (user and organization) from GitHub, including all branches and tags.
- **Handles duplicates**: Appends DUPLICATE_#_ to repository folder names when duplicates are detected.
- **Handles orphaned repositories**: Appends ORPHAN_ to the folder names of repositories that no longer exist on GitHub, ensuring data is never lost.
- **Retry mechanism**: If the clone or update process fails, the script retries up to 3 times.
- **Graceful error handling**: Errors and interruptions are logged for review.
- **Non-destructive**: Existing repositories are updated, not overwritten, and orphaned repositories are preserved.

## Requirements
- **Git**: Ensure that Git is installed on your machine.
- **GitHub CLI (gh)**: Install the GitHub CLI using the following command:

  `brew install gh`

- **SSH key**: You must have your SSH key set up with GitHub for authentication.

## Setup

1. **Clone this repository**:

   `git clone git@github.com:mav2287/GitHubBackupScript.git`

2. **Set up your backup folder**:

   By default, the script will create a folder named github_backup in the same directory as the script. If you want to specify a different backup location, you can pass the folder path as a parameter when running the script.

3. **SSH Key Setup**:

   Ensure that your SSH key is added to your GitHub account. You can test your connection with:

   `ssh -T git@github.com`

4. **Edit .gitignore**:

   The default .gitignore is configured to exclude the github_backup/ folder and log files.

## Usage

To run the script, you can use the following command:

`bash backup_repos.sh`

By default, it will:
- Back up all repositories into the github_backup folder.
- Fetch all branches and tags for each repository.
- Create a repos.txt file to log all the repositories being backed up. The file will distinguish between user and organization repositories using USER [username] and ORG [org_name].
- Log errors into error_log.txt for review.

### Optional Parameters

- **Backup Directory**: Specify a different backup directory:

  `bash backup_repos.sh /path/to/your/backup/folder`

- **Silent Mode**: Use the -s option to run the script in silent mode, useful for scheduled tasks like cron jobs:

  `bash backup_repos.sh -s`

- **Orphan Cleanup**: If you want to clean up orphaned repositories (repositories that no longer exist on GitHub), use the -c option:

  `bash backup_repos.sh -c`

### Repository Handling:
- **Duplicates**: If a repository with the same name exists, the script will create a new folder with the format DUPLICATE_#_repo_name to avoid overwriting existing backups.
- **Orphans**: If a repository no longer exists on GitHub, the script renames it with an ORPHAN_ prefix instead of deleting it, ensuring no data is lost.

## Scheduling Backups

You can schedule this script to run regularly using a cron job on Linux/macOS.

1. Open the cron table:

   `crontab -e`

2. Add the following line to schedule the script to run every day at 2 AM:

   `0 2 * * * /path/to/your/backup_repos.sh -s`

3. Save and exit the cron table.

## Logs

- **Log File**: All script activity is logged in backup_log.txt.
- **Error Log**: Any errors encountered during execution are logged in error_log.txt.

## Example

Here is an example of running the script with all optional parameters:

`bash backup_repos.sh /path/to/backup/folder -s -c`

This will run the script in silent mode, store the backups in /path/to/backup/folder, and clean up orphaned repositories.

## Security Considerations

- The script dynamically fetches GitHub SSH keys for secure authentication without making permanent changes to the known_hosts file.
- Repository names, user/org names, and other variables are sanitized to prevent issues with malicious inputs or characters.
- Non-destructive: The script does not delete data, even if repositories are deleted from GitHub.

## License

This script is open source and available under the MIT License.
