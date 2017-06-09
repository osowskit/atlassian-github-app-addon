require 'jwt'
require 'rest_client'
require 'json'
require 'active_support/all'
require 'octokit'
require 'sinatra'

$stdout.sync = true

begin
  GITHUB_CLIENT_ID = ENV.fetch("GITHUB_CLIENT_ID")
  GITHUB_CLIENT_SECRET =  ENV.fetch("GITHUB_CLIENT_SECRET")
  GITHUB_APP_KEY = ENV.fetch("GITHUB_APP_KEY")
  GITHUB_APP_ID = ENV.fetch("GITHUB_APP_ID")
rescue KeyError
  $stderr.puts "To run this script, please set the following environment variables:"
  $stderr.puts "- GITHUB_CLIENT_ID: GitHub Developer Application Client ID"
  $stderr.puts "- GITHUB_CLIENT_SECRET: GitHub Developer Application Client Secret"
  $stderr.puts "- GITHUB_APP_KEY: GitHub App Private Key"
  $stderr.puts "- GITHUB_APP_ID: GitHub App ID"
  exit 1
end

use Rack::Session::Cookie, :secret => rand.to_s()
set :protection, :frame_options => "ALLOW-FROM *"
Octokit.default_media_type = "application/vnd.github.machine-man-preview+json"

# Sinatra Endpoints
# -----------------
client = Octokit::Client.new

get '/callback' do 
  session_code = params[:code]
  result = Octokit.exchange_code_for_token(session_code, GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET)
  session[:access_token] = result[:access_token]
  redirect to('/')
end

# Handle GitHub App webhook events
post '/payload' do
  github_event = request.env['HTTP_X_GITHUB_EVENT']
  if github_event == "integration_installation" || github_event == "installation_repositories"
    parse_installation_payload(request.body.read)
  else
    puts "New event #{github_event}"
  end

end

# Entry point for JIRA Add-on.
# JIRA passes in a number of URL parameters https://goo.gl/zyGLiF
get '/main_entry' do
  # Handle loading outside of JIRA environment
  jira_issue =  request.referrer.nil? ? nil : request.referrer.split('/').last
  session[:jira_issue] = !jira_issue.nil? ? jira_issue : "JIRA-BRANCH"

  $fqdn = params[:xdm_e].nil? ? "" : params[:xdm_e]

  redirect to('/')
end

# Main application logic
get '/' do
  # Ensure user is authenticated with OAuth token
  if !authenticated?
    @url = client.authorize_url(GITHUB_CLIENT_ID)
    if session[:jira_issue].nil?
      session[:jira_issue] = "JIRA-BOT-BRANCH"
    end
    return erb :authorize
  else
    
    if !set_app_token?
      if session[:installation_id].nil?
        session[:installation_id] = get_user_installations(session[:access_token])
        if session[:installation_id].nil?
          return erb :install_app
        end
      end
      token_url = "https://api.github.com/installations/#{session[:installation_id]}/access_tokens"
      session[:app_token] = get_app_token(token_url)
      redirect to('/')
    else
      if !set_repo?
        @name_list = [] 
        # Get all repositories a user has write access to
        repositories = get_app_repositories(session[:app_token])

        repositories.each do |repo|
          @name_list.push(repo["full_name"]) 
          # if repo["permissions"]["admin"] || repo["permissions"]["push"] 
        end
        session[:name_list] = @name_list
        # Show end-user a list of all repositories they can create a branch in
        return erb :show_repos
      else
        if branch_exists?
          return erb :link_to_branch
        end      
        @repo_name = session[:repo_name]
        return erb :create_branch
      end
    end
  end
end


# Clear all session information
get '/logout' do
  session[:access_token] = nil
  session[:repo_name] = nil
  session[:name_list] = nil
  session[:branch_name] = nil
  session[:jira_issue] = nil
  session[:installation_id] = nil
  session[:app_token] = nil
  redirect to('/')
end

# Create a branch for the selected repository if it doesn't already exist.
get '/create_branch' do
  if !authenticated? || !set_repo?
    redirect to('/')
  end
  client = Octokit::Client.new(:access_token => session[:app_token] )

  repo_name = session[:repo_name]
  branch_name = session[:jira_issue]
  begin
    # Does this branch exist
    sha = client.ref(repo_name, "heads/#{branch_name}")
    session[:branch_name] = branch_name
  rescue Octokit::NotFound
    # Create branch
    sha = client.ref(repo_name, "heads/master")[:object][:sha]
    ref = client.create_ref(repo_name, "heads/#{branch_name}", sha.to_s)
    session[:branch_name] = branch_name
  end
  redirect to('/')
end

# Store which Repository the user selected 
get '/add_repo' do
  if !authenticated?
    redirect to('/')
  end

  input_repo = params[:repo_name]
  session[:repo_name] = input_repo if session[:name_list].include? input_repo.to_s  
  redirect to('/')
end

# Public route to install Add-on from Atlassian
get '/atlassian-connect.json' do
  content_type :json
  File.read(File.join('public', 'atlassian-connect.json'))
end


# JIRA session methods
# -----------------

# Returns true if the user completed OAuth2 handshake and has a token
def authenticated?
  !session[:access_token].nil?
end

# Returns whether the user selected a repository to map to this JIRA project
def set_repo?
  !session[:repo_name].nil?
end

# Returns whether a branch for this issue already exists 
def branch_exists?
  !session[:branch_name].nil?
end

def installed_app?
  !session[:installation_id].nil?
end

def set_app_token?
  !session[:app_token].nil?
end

# GitHub Apps helper methods
# -----------------

def get_jwt
  private_pem = GITHUB_APP_KEY
  private_key = OpenSSL::PKey::RSA.new(private_pem)

  payload = {
    # issued at time
    iat: Time.now.to_i,
    # JWT expiration time (10 minute maximum)
    exp: 5.minutes.from_now.to_i,
    # Integration's GitHub identifier
    iss: GITHUB_APP_ID
  }

  JWT.encode(payload, private_key, "RS256")
end

def get_user_installations(token)
  url = "https://api.github.com/user/installations"
  headers = {
    authorization: "token #{token}",
    accept: "application/vnd.github.machine-man-preview+json"
  }
  
  response = RestClient.get(url,headers)
  json_response = JSON.parse(response)

  installation_id = nil
  if json_response["total_count"] > 0
    installation_id = json_response["installations"].first()["id"]
  end
  installation_id
end

def get_app_repositories(token)
  url = "https://api.github.com/installation/repositories"
  headers = {
    authorization: "token #{token}",
    accept: "application/vnd.github.machine-man-preview+json"
  }

  response = RestClient.get(url,headers)
  json_response = JSON.parse(response)

  repository_list = []
  if json_response["total_count"] > 0
    json_response["repositories"].each do |repo|
      repository_list.push(repo)
    end
  end

  repository_list
end

def get_app_token(access_tokens_url)
  jwt = get_jwt

  headers = {
    authorization: "Bearer #{jwt}",
    accept: "application/vnd.github.machine-man-preview+json"
  }
  response = RestClient.post(access_tokens_url,{},headers)

  app_token = JSON.parse(response)
  app_token["token"]
end


def parse_installation_payload(json_body)
  webhook_data = JSON.parse(json_body)
  if webhook_data["action"] == "created" || webhook_data["action"] == "added"
    access_tokens_url = webhook_data["installation"]["access_tokens_url"]
    # Get token for app
    app_token = get_app_token(access_tokens_url)
    
    repository_list = []
    if webhook_data["installation"].key?("repositories_added")
      webhook_data["installation"]["repositories_added"].each do |repo|
        repository_list.push(repo["full_name"])
      end
    else
      # Get repositories by query
      repository_list = get_app_repositories(app_token) 
    end
    
    create_issues(app_token, repository_list, webhook_data["sender"]["login"])
  end
end


# Octokit methods
# -----------------

def create_issues(access_token, repositories, sender_username)
  client = Octokit::Client.new(access_token: access_token )
  client.default_media_type = "application/vnd.github.machine-man-preview+json"

  repositories.each do |repo|
    begin
      client.create_issue(repo, "#{sender_username} created new app!", "Added GitHub App")
    rescue
      puts "no issues in this repository"
    end
  end
end
