# Create GitHub Branches from Jira

## Usage

This [Atlassian Marketplace add-on](https://marketplace.atlassian.com/plugins/com.osowskit.jira.github.app/cloud/overview) provides the convenience of creating branches in GitHub from a JIRA ticket. Create and view GitHub branches directly from a JIRA issue.

* Install the add-on : https://marketplace.atlassian.com/1217260

<img width="738" alt="Screen Shot 2023-05-15 at 8 15 56 PM" src="https://github.com/osowskit/atlassian-github-app-addon/assets/768821/4cf31f58-f69b-4344-9279-03e6865fc722">

* Simply add the GitHub App to your account : https://github.com/apps/jira-bot and select which repositories you want to create branches in

* Navigate to any ticket on your JIRA instance an click the `Connect to GitHub` link 

<img src="https://user-images.githubusercontent.com/768821/34046355-9bff2df6-e161-11e7-9c6f-a1ec03b84a28.png" width="250">

* Create and view branches in a JIRA ticket.

* View any Pull Request for the branch

<img src="https://user-images.githubusercontent.com/768821/32191639-0bb9e878-bd6f-11e7-9fb2-7b85b5f0328b.png" width="350">

## Custom Branch Names

The default branch pattern will use the issue key as the branch name and create this off of the main default branch. It is possible to set a GitFlow branching pattern and also use a custom branch name as outlined below.

### Custom Branch Name

Users can choose to manually enter the branch name by using a per Repository config file. This allows the user to add custom text as the branch name and be created off of the main default branch, e.g. `SENG-1234/my-great-feature`. Set this for each repository using this pattern:

1. Add the following file `.github/jira-bot.yaml` to the main default branch
1. Set the file contents to be `branch_pattern: 2`
1. In Jira, with the plugin loaded, remove and re-add each repository that has been updated. (The branch pattern is cached and needs to be refreshed).

<img width="224" alt="Screen Shot 2023-05-15 at 8 24 49 PM" src="https://github.com/osowskit/atlassian-github-app-addon/assets/768821/d818d9c5-4d0b-4763-94ec-4df49714337c">

### GitFlow

Users can select the GitFlow branching pattern in the config file that will create a feature branch off of the `develop` branch, e.g. `feature/SENG-1234`. For each repository, use this pattern:

1. Add the following file `.github/jira-bot.yaml` to the Repository's default branch
1. Set the file contents to be `branch_pattern: 1`
1. In Jira with the plugin loaded, remove and re-add each repository that has been updated. (The branch pattern is cached and needs to be refreshed).

### GitFlow + Custom Branch Name (deprecated)

Users can select the GitFlow branching pattern in the config file that will create a feature branch off of the `develop` branch, e.g. `feature/SENG-1234`. This option allows users to also set the branch name via the UI. This setting is deprecated and users should set `branch_pattern: 3` and `default_base_branch_name: 'develop'` going forward.

For each repository, use this pattern:

1. Add the following file `.github/jira-bot.yaml` to the Repository's default branch
1. Set the file contents to be `branch_pattern: 3`
1. In Jira with the plugin loaded, remove and re-add each repository that has been updated. (The branch pattern is cached and needs to be refreshed).

### Custom Base Branch

Teams that have branching patterns that are created off a branch that isn't the Repository's default branch. The following configuration allows users to set the base branch where new branches are created from. 

For each repository, use this pattern:

1. Add the following file `.github/jira-bot.yaml` to the Repository's default branch
1. Set the file contents to be `default_base_branch_name: 'dev'`
1. In Jira with the plugin loaded, remove and re-add each repository that has been updated. (The branch pattern is cached and needs to be refreshed).

Here is the approved branch name list. Please open an issue to request a new branch
```
['master', 'main', 'development', 'dev', 'feature', 'hotfix', 'release', 'test', 'testing']
```

[Example yaml file](https://github.com/osowskit/an-repo/blob/master/.github/jira-bot.yaml)
