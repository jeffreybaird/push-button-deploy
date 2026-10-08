require 'test_helper'

class HealthTest < ActionDispatch::IntegrationTest
  test 'health endpoint responds successfully' do
    get '/health'
    assert_response :success
  end
end
