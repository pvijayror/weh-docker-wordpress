require_relative '../../../test_helper'

class OmniAuth::Strategies::OpenIDConnectTest < StrategyTestCase
  def test_client_options_defaults
    assert_equal "https", strategy.options.client_options.scheme
    assert_equal 443, strategy.options.client_options.port
    assert_equal "/authorize", strategy.options.client_options.authorization_endpoint
    assert_equal "/token", strategy.options.client_options.token_endpoint
  end

  def test_request_phase
    expected_redirect = /^https:\/\/example\.com\/authorize\?client_id=1234&nonce=[\w\d]{32}&response_type=code&scope=openid$/
    strategy.options.client_options.host = "example.com"
    strategy.expects(:redirect).with(regexp_matches(expected_redirect))
    strategy.request_phase
  end

  def test_uid
    assert_equal user_info.sub, strategy.uid
  end

  def test_callback_phase(session = {}, params = {})
    code = SecureRandom.hex(16)
    request.stubs(:params).returns({"code" => code}.merge(params))
    request.stubs(:path_info).returns("")

    strategy.unstub(:user_info)
    access_token = stub('OpenIDConnect::AccessToken')
    access_token.stubs(:access_token)
    client.expects(:access_token!).returns(access_token)
    access_token.expects(:userinfo!).returns(user_info)

    strategy.call!({"rack.session" => session})
    strategy.callback_phase
  end

  def test_info
    info = strategy.info
    assert_equal user_info.name, info[:name]
    assert_equal user_info.email, info[:email]
    assert_equal user_info.preferred_username, info[:nickname]
    assert_equal user_info.given_name, info[:first_name]
    assert_equal user_info.family_name, info[:last_name]
    assert_equal user_info.picture, info[:image]
    assert_equal user_info.phone_number, info[:phone]
    assert_equal({ website: user_info.website }, info[:urls])
  end

  def test_extra
    assert_equal({ raw_info: user_info.as_json }, strategy.extra)
  end

  def test_credentials
    access_token = stub('OpenIDConnect::AccessToken')
    access_token.stubs(:access_token).returns(SecureRandom.hex(16))
    client.expects(:access_token!).returns(access_token)

    assert_equal({ token: access_token.access_token }, strategy.credentials)
  end

  def test_option_client_auth_method
    opts = strategy.options.client_options
    opts[:host] = "foobar.com"
    strategy.options.client_auth_method = :not_basic
    success = Struct.new(:status).new(200)

    HTTPClient.any_instance.stubs(:post).with(
      "#{opts.scheme}://#{opts.host}:#{opts.port}#{opts.token_endpoint}",
      {:grant_type => :client_credentials, :client_id => @identifier, :client_secret => @secret},
      {}
    ).returns(success)
    OpenIDConnect::Client.any_instance.stubs(:handle_success_response).with(success).returns(true)

    assert(strategy.send :access_token)
  end

  def test_failure_endpoint_redirect
    OmniAuth.config.stubs(:failure_raise_out_environments).returns([])
    strategy.stubs(:env).returns({})
    request.stubs(:params).returns({"error" => "access denied"})

    result = strategy.callback_phase

    assert(result.is_a? Array)
    assert(result[0] == 302, "Redirect")
    assert(result[1]["Location"] =~ /\/auth\/failure/)
  end

  def test_option_send_nonce
    strategy.options.client_options[:host] = "foobar.com"

    assert(strategy.authorize_uri =~ /nonce=/, "URI must contain nonce")

    strategy.options.send_nonce = false
    assert(!(strategy.authorize_uri =~ /nonce=/), "URI must not contain nonce")
  end

  def test_state
    strategy.options.state = lambda { 42 }
    session = { "state" => 42 }

    expected_redirect = /&state=/
    strategy.options.client_options.host = "example.com"
    strategy.expects(:redirect).with(regexp_matches(expected_redirect))
    strategy.request_phase

    # this should succeed as the correct state is passed with the request
    test_callback_phase(session, { "state" => 42 })

    # the following should fail because the wrong state is passed to the callback
    code = SecureRandom.hex(16)
    request.stubs(:params).returns({"code" => code, "state" => 43})
    request.stubs(:path_info).returns("")
    strategy.call!({"rack.session" => session})

    result = strategy.callback_phase

    assert result.kind_of?(Array)
    assert result.first == 401, "Expecting unauthorized"
  end
end
