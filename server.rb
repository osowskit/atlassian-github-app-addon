require 'jwt'
require 'rest_client'
require 'json'
require 'active_support/all'
require 'octokit'
require 'sinatra'
require 'sinatra/cookies'
require 'uri'
require 'yaml'

$stdout.sync = true
$tamper_xor = 111111
$fqdn = nil
$default_branch_name = "JIRA-BOT-BRANCH"

begin
  yml = File.open('jira-bot.yaml')
  contents = YAML.load(yml)

  GITHUB_CLIENT_ID = contents["client_id"]
  GITHUB_CLIENT_SECRET = contents["client_secret"]
  GITHUB_APP_KEY = File.read(contents["private_key"])
  GITHUB_APP_ID = contents["app_id"]
  GITHUB_APP_URL = contents["app_url"]
rescue
  begin
    GITHUB_CLIENT_ID = ENV.fetch("GITHUB_CLIENT_ID")
    GITHUB_CLIENT_SECRET =  ENV.fetch("GITHUB_CLIENT_SECRET")
    GITHUB_APP_KEY = ENV.fetch("GITHUB_APP_KEY")
    GITHUB_APP_ID = ENV.fetch("GITHUB_APP_ID")
    GITHUB_APP_URL = ENV.fetch("GITHUB_APP_URL")
  rescue KeyError
    $stderr.puts "To run this script, please set the following environment variables:"
    $stderr.puts "- GITHUB_CLIENT_ID: GitHub Developer Application Client ID"
    $stderr.puts "- GITHUB_CLIENT_SECRET: GitHub Developer Application Client Secret"
    $stderr.puts "- GITHUB_APP_KEY: GitHub App Private Key"
    $stderr.puts "- GITHUB_APP_ID: GitHub App ID"
    $stderr.puts "- GITHUB_APP_URL: GitHub App URL"
    exit 1
  end
end

configure do
  enable :cross_origin
end

before do
  response.headers['Access-Control-Allow-Origin'] = 'https://*.atlassian.net'
end

options "*" do
  response.headers["Allow"] = "GET, POST, OPTIONS"
  response.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type, Accept, X-User-Email, X-Auth-Token"
  response.headers["Access-Control-Allow-Origin"] = "*"
  response.headers["X-Content-Security-Policy"] = "frame-ancestors https://*.atlassian.net";
  response.headers["Content-Security-Policy"] = "frame-ancestors https://*.atlassian.net";
  200
end

use Rack::Session::Cookie, :secret => rand.to_s()
set :protection, :except => :frame_options
set :public_folder, 'public'
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

# GitHub will include `installation_id` after installing the App
get '/post_app_install' do
  set_installation_cookie(params[:installation_id])
  redirect to('/')
end

# Entry point for JIRA Add-on.
# JIRA passes in a number of URL parameters https://goo.gl/zyGLiF
get '/main_entry' do
  # Used in templates to load JS and CSS
  $fqdn = params[:xdm_e].nil? ? "" : params[:xdm_e]

  # JIRA ID is passed as context-parameters.
  # Referenced in atlassian-connect.json
  session[:jira_issue] = params.fetch("issueKey", $default_branch_name)
  redirect to('/')
end

# Main application logic
get '/' do
  if session[:jira_issue].nil?
    session[:jira_issue] = $default_branch_name
  end

  # Generate an GitHub App token from the user's installation
  if !set_app_token?
    # Do we have the App's installation id. If so, no user authentication needed
    if !installation_cookie?
      # Need user's OAuth token to lookup instllation id
      if !authenticated?
        @url = client.authorize_url(GITHUB_CLIENT_ID)
        return erb :authorize
      else
        session[:installation_id] = get_user_installations(session[:access_token])

        # User does not have App installed
        if session[:installation_id].nil?
          @app_url = GITHUB_APP_URL
          return erb :install_app
        end
        set_installation_cookie(session[:installation_id])
      end
    end

    # Generate GitHub App token
    token_url = "https://api.github.com/installations/#{get_installation_cookie}/access_tokens"
    session[:app_token] = get_app_token(token_url)
    redirect to('/')
  end

  if !set_repo?
    @name_list = []
    # Get all repositories a user has write access to
    repositories = get_app_repositories(session[:app_token])

    repositories.each do |repo|
      @name_list.push(repo["full_name"])
    end
    session[:name_list] = @name_list
    # Show end-user a list of all repositories they can create a branch in
    return erb :show_repos
  else

    if branch_exists?(session[:jira_issue])
      send_event(get_installation_cookie, "plugin", "show", "branch")
      return erb :link_to_branch
    end
    
    # Authenticated but not viewing JIRA ticket
    if session[:jira_issue] == $default_branch_name
      return erb :thank_you
    end

    @repo_name = session[:repo_name]
    return erb :create_branch
  end
end

#
post '/payload' do
  github_event = request.env['HTTP_X_GITHUB_EVENT']
  webhook_data = JSON.parse(request.body.read)

  if github_event == "installation" || github_event == "installation_repositories"
    puts "installation event"
  else
    puts "New event #{github_event}"
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
  cookies.delete("installation_id")
  redirect to('/')
end

# Create a branch for the selected repository if it doesn't already exist.
get '/create_branch' do
  if !set_app_token? || !set_repo? || branch_exists?(session[:jira_issue])
    redirect to('/')
  end
  client = Octokit::Client.new(:access_token => session[:app_token] )

  repo_name = session[:repo_name]
  branch_name = session[:jira_issue]
  begin
    # Create branch at tip of master
    sha = client.ref(repo_name, "heads/master")[:object][:sha]
    ref = client.create_ref(repo_name, "heads/#{branch_name}", sha.to_s)

  rescue
    puts "Failed to create branch #{branch_name}"
  end
  redirect to('/')
end

# Store which Repository the user selected
get '/add_repo' do
  if !set_app_token?
    redirect to('/')
  end

  input_repo = params[:repo_name]
  session[:repo_name] = input_repo if session[:name_list].include? input_repo.to_s
  redirect to('/')
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
def branch_exists?(jira_issue)
  client = Octokit::Client.new(:access_token => session[:app_token] )

  repo_name = session[:repo_name]
  branch_name = jira_issue

  begin
    # Does this branch exist
    sha = client.ref(repo_name, "heads/#{branch_name}")
  rescue
    return false
  end
  return true
end

def installed_app?
  !session[:installation_id].nil?
end

def set_app_token?
  !session[:app_token].nil?
end

def installation_cookie?
  !cookies[:installation_id].nil?
end

def set_installation_cookie(value)
  tamper = value.to_i^$tamper_xor
  cookies[:installation_id] = tamper
end

def get_installation_cookie
  tamper = cookies[:installation_id]
  tamper = tamper.to_i^$tamper_xor
  tamper.to_s
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

  repository_list = []
  begin
    response = RestClient.get(url,headers)
    json_response = JSON.parse(response)

    if json_response["total_count"] > 0
      json_response["repositories"].each do |repo|
        repository_list.push(repo)
      end
    end
  rescue
    # Likely a 401 so renew token
    session[:app_token] = nil
    redirect to('/')
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
