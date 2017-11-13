require 'jwt'
require 'rest_client'
require 'json'
require 'active_support/all'
require 'octokit'
require 'sinatra'
require 'sinatra/cookies'
require 'uri'
require 'yaml'
require 'securerandom'

$stdout.sync = true
$default_branch_name = "JIRA-BOT-BRANCH"

begin
  yml = File.open('jira-bot.yaml')
  contents = YAML.load(yml)

  GITHUB_CLIENT_ID = contents["client_id"]
  GITHUB_CLIENT_SECRET = contents["client_secret"]
  GITHUB_APP_KEY = File.read(contents["private_key"])
  GITHUB_APP_ID = contents["app_id"]
  GITHUB_APP_URL = contents["app_url"]
  COOKIE_SECRET = contents["cookie_secret"]
rescue
  begin
    GITHUB_CLIENT_ID = ENV.fetch("GITHUB_CLIENT_ID")
    GITHUB_CLIENT_SECRET =  ENV.fetch("GITHUB_CLIENT_SECRET")
    GITHUB_APP_KEY = ENV.fetch("GITHUB_APP_KEY")
    GITHUB_APP_ID = ENV.fetch("GITHUB_APP_ID")
    GITHUB_APP_URL = ENV.fetch("GITHUB_APP_URL")
    COOKIE_SECRET = ENV.fetch("COOKIE_SECRET")
  rescue KeyError
    $stderr.puts "To run this script, please set the following environment variables:"
    $stderr.puts "- GITHUB_CLIENT_ID: GitHub Developer Application Client ID"
    $stderr.puts "- GITHUB_CLIENT_SECRET: GitHub Developer Application Client Secret"
    $stderr.puts "- GITHUB_APP_KEY: GitHub App Private Key"
    $stderr.puts "- GITHUB_APP_ID: GitHub App ID"
    $stderr.puts "- GITHUB_APP_URL: GitHub App URL"
    $stderr.puts "- COOKIE_SECRET: Integrity check for Session Cookies"
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

use Rack::Session::Cookie, :secret => COOKIE_SECRET.to_s()
set :protection, :except => :frame_options
set :public_folder, 'public'
set :static_cache_control, [:public, :max_age => 2678400]
Octokit.default_media_type = "application/vnd.github.machine-man-preview+json"

# Sinatra Endpoints
# -----------------
client = Octokit::Client.new

get '/callback' do
  session_code = params[:code]
  result = Octokit.exchange_code_for_token(session_code, GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET)
  session[:access_token] = result[:access_token]

  return erb :close
end

# GitHub will include `installation_id` after installing the App
get '/post_app_install' do
  # Send the user back to JIRA
  if !session[:referrer].nil? && session[:referrer] != ''
    redirect session[:referrer]
  end

  return erb :close
end

# Entry point for JIRA Add-on.
# JIRA passes in a number of URL parameters https://goo.gl/zyGLiF
get '/main_entry' do
  # Used in templates to load JS and CSS
  session[:fqdn] = params[:xdm_e].nil? ? "" : params[:xdm_e]
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

  # Need user's OAuth token to lookup installation id
  if !authenticated?
    @url = client.authorize_url(GITHUB_CLIENT_ID)
    return erb :login
  end

  if !set_repo?
    @name_list = get_user_repositories(session[:access_token])
    if @name_list.length == 0
      puts @name_list
      @app_url = GITHUB_APP_URL
      return erb :install_app
    end
    session[:name_list] = @name_list
    # Show end-user a list of all repositories they can create a branch in
    return erb :show_repos
  else

    if branch_exists?(session[:jira_issue])

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
  session.delete(:repo_name)
  session.delete(:name_list)
  session.delete(:app_token)
  session.delete(:access_token)
  redirect to('/')
end

# Create a branch for the selected repository if it doesn't already exist.
get '/create_branch' do
  if !set_repo? || branch_exists?(session[:jira_issue])
    redirect to('/')
  end
  app_token = get_app_token(session[:repo_name][:installation_id])
  client = Octokit::Client.new(:access_token => app_token )

  repo_name = session[:repo_name][:full_name]
  branch_name = session[:jira_issue]
  begin
    # Look up default branch
    repo_data = client.repository(repo_name)
    default_branch = repo_data[:default_branch]

    # Create branch at tip of the default branch
    sha = client.ref(repo_name, "heads/#{default_branch}")[:object][:sha]
    ref = client.create_ref(repo_name, "heads/#{branch_name}", sha.to_s)

  rescue
    puts "Failed to create branch #{branch_name}"
    redirect to('/logout')
  end
  redirect to('/')
end

# Store which Repository the user selected
get '/add_repo' do
  if !authenticated?
    redirect to('/')
  end

  input_repo = params[:repo_name]

  # need to check if repo is in the list
  session[:name_list].each do |repository_name|
    if input_repo == repository_name[:full_name]
      session[:repo_name] = repository_name
      break
    end
  end
  redirect to('/')
end


# JIRA session methods
# -----------------

# Returns true if the user completed OAuth2 handshake and has a token
def authenticated?
  !session[:access_token].nil? && session[:access_token] != ''
end

# Returns whether the user selected a repository to map to this JIRA project
def set_repo?
  !session[:repo_name].nil? && session[:repo_name] != ''
end

# Returns whether a branch for this issue already exists
def branch_exists?(jira_issue)

  app_token = get_app_token(session[:repo_name][:installation_id])
  client = Octokit::Client.new(:access_token => app_token)

  repo_name = session[:repo_name][:full_name]
  branch_name = jira_issue

  begin
    # Does this branch exist
    sha = client.ref(repo_name, "heads/#{branch_name}")
  rescue
    return false
  end
  return true
end

def get_event_session_id
  if session[:user_session_id].nil? || session[:user_session_id] == '' 
    session[:user_session_id] = SecureRandom.uuid()
    puts "Created session id #{session[:user_session_id]}"
  end
  session[:user_session_id]
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

def get_user_installations(access_token)
  url = "https://api.github.com/user/installations"
  headers = {
    authorization: "token #{access_token}",
    accept: "application/vnd.github.machine-man-preview+json"
  }

  response = RestClient.get(url,headers)
  json_response = JSON.parse(response)

  installation_id = []
  if json_response["total_count"] > 0
    json_response["installations"].each do |installation|
      installation_id.push(installation["id"])
    end
  end
  installation_id
end


def get_user_repositories(access_token)
  repository_list = []
  ids = get_user_installations(access_token)
  ids.each do |id|
    url ="https://api.github.com/user/installations/#{id}/repositories"
    headers = {
      authorization: "token #{access_token}",
      accept: "application/vnd.github.machine-man-preview+json"
    }
    begin
      response = RestClient.get(url,headers)
      json_response = JSON.parse(response)

      if json_response["total_count"] > 0
        json_response["repositories"].each do |repo|
          repository_list.push({
            full_name: repo["full_name"],
            installation_id: id
          })
        end
      end
    rescue => error
      puts "User Repo Error : #{error}"
    end
  end
  repository_list
end

def get_app_token(installation_id)
  token_url = "https://api.github.com/installations/#{installation_id}/access_tokens"
  jwt = get_jwt
  return_val = ""
  headers = {
    authorization: "Bearer #{jwt}",
    accept: "application/vnd.github.machine-man-preview+json"
  }
  begin
    response = RestClient.post(token_url,{},headers)
    app_token = JSON.parse(response)
    return_val = app_token["token"]
  rescue => error
    puts "app_access_token #{error}"
  end
  return_val
end
