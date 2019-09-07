# Create GitHub Branches from Jira

## Usage

This [Atlassian Marketplace add-on](https://marketplace.atlassian.com/plugins/com.osowskit.jira.github.app/cloud/overview) provides the convenience of creating branches in GitHub from a JIRA ticket. Create and view GitHub branches directly from a JIRA issue.

* Install the add-on : https://marketplace.atlassian.com/1217260

<img src="https://user-images.githubusercontent.com/768821/34046131-d45413fc-e160-11e7-89ca-a26f7993554c.png" width="650">

* Simply add the GitHub App to your account : https://github.com/apps/jira-bot and select which repositories you want to create branches in

* Navigate to any ticket on your JIRA instance an click the `Connect to GitHub` link 

<img src="https://user-images.githubusercontent.com/768821/34046355-9bff2df6-e161-11e7-9c6f-a1ec03b84a28.png" width="250">

* Create and view branches in a JIRA ticket.

* View any Pull Request for the branch

<img src="https://user-images.githubusercontent.com/768821/32191639-0bb9e878-bd6f-11e7-9fb2-7b85b5f0328b.png" width="350">

## Custom Branch Names

The default branch patter will use the issue key as the branch name and create this off of `master`. It is possible to set a GitFlow branching pattern and also use a custom branch name.

### GitFlow

Users can select the GitFlow branching pattern in the config file that will create a feature branch off of the `develop` branch, e.g. `feature/SENG-1234`. For each repository that uses this pattern:

1. Add the following file `.github/jira-bot.yaml` to `master`
1. Set the file contents to be `branch_pattern: 1`
1. In Jira with the plugin loaded, remove and re-add each repository that has been updated. (The branch pattern is cached and needs to be refreshed).

### Custom Branch 

Users can choose to manually enter the branch name in the config file that will create a new branch off of the `master` branch, e.g. `SENG-1234/my-great-feature`. For each repository that uses this pattern:

1. Add the following file `.github/jira-bot.yaml` to `master`
1. Set the file contents to be `branch_pattern: 2`
1. In Jira with the plugin loaded, remove and re-add each repository that has been updated. (The branch pattern is cached and needs to be refreshed).

[Example yaml file](https://github.com/osowskit/an-repo/blob/master/.github/jira-bot.yaml)
