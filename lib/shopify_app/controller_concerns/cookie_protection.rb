# frozen_string_literal: true

require 'browser_sniffer'

module ShopifyApp
  module CookieProtection
    extend ActiveSupport::Concern

    class ShopifyDomainNotFound < StandardError; end

    included do
      include ShopifyApp::Itp
      after_action :set_test_cookie
      rescue_from ActiveResource::UnauthorizedAccess, with: :close_session
    end

    def activate_shopify_session
      if current_shopify_session.blank?
        Rails.logger.debug("[ShopifyApp::LoginProtection] Current shopify session is blank. Redirecting to login...")
        return redirect_to_login
      end

      clear_top_level_oauth_cookie

      begin
        Rails.logger.debug("[ShopifyApp::LoginProtection] Activating session...")
        ShopifyAPI::Base.activate_session(current_shopify_session)
        yield
      ensure
        Rails.logger.debug("[ShopifyApp::LoginProtection] Clearing session...")
        ShopifyAPI::Base.clear_session
      end
    end

    def current_shopify_session
      @current_shopify_session ||=
        begin
          user_session || shop_session
        end
    end

    def current_shopify_domain
      shopify_domain = sanitized_shop_name || session[:shopify_domain]
      return shopify_domain if shopify_domain.present?

      raise ShopifyDomainNotFound
    end

    private

    def user_session
      return unless session[:user_id].present?
      ShopifyApp::SessionRepository.retrieve_user_session(session[:user_id])
    end

    def shop_session
      return unless session[:shop_id].present?
      ShopifyApp::SessionRepository.retrieve_shop_session(session[:shop_id])
    end

    def close_session
      clear_shopify_session
      redirect_to(login_url_with_optional_shop)
    end

    def clear_shopify_session
      session[:shop_id] = nil
      session[:user_id] = nil
      session[:shopify_domain] = nil
      session[:shopify_user] = nil
      session[:user_session] = nil
    end

    def redirect_to_login
      if request.xhr?
        head(:unauthorized)
      else
        if request.get?
          path = request.path
          query = sanitized_params.to_query
        else
          referer = URI(request.referer || "/")
          path = referer.path
          query = "#{referer.query}&#{sanitized_params.to_query}"
        end
        session[:return_to] = query.blank? ? path.to_s : "#{path}?#{query}"
        redirect_to(login_url_with_optional_shop)
      end
    end

    def login_again_if_different_user_or_shop
      if session[:user_session].present? && params[:session].present? # session data was sent/stored correctly
        Rails.logger.debug("[ShopifyApp::LoginProtection] Session data was sent/stored correctly.")
        clear_session = session[:user_session] != params[:session] # current user is different from stored user
        if clear_session
          Rails.logger.debug("[ShopifyApp::LoginProtection] Current user is different from stored user.")
        end
        clear_session
      end

      if current_shopify_session &&
          params[:shop] && params[:shop].is_a?(String) &&
          (current_shopify_session.domain != params[:shop])
        clear_session = true
      end

      if clear_session
        Rails.logger.debug("[ShopifyApp::LoginProtection] Clearing shopify session and redirecting to login...")
        clear_shopify_session
        redirect_to_login
      end
    end

    def login_url_with_optional_shop(top_level: false)
      url = ShopifyApp.configuration.login_url

      query_params = login_url_params(top_level: top_level)

      url = "#{url}?#{query_params.to_query}" if query_params.present?
      url
    end

    def login_url_params(top_level:)
      query_params = {}
      query_params[:shop] = sanitized_params[:shop] if params[:shop].present?

      return_to = RedirectSafely.make_safe(session[:return_to] || params[:return_to], nil)

      if return_to.present? && return_to_param_required?
        query_params[:return_to] = return_to
      end

      has_referer_shop_name = referer_sanitized_shop_name.present?

      if has_referer_shop_name
        query_params[:shop] ||= referer_sanitized_shop_name
      end

      query_params[:top_level] = true if top_level
      query_params
    end

    def return_to_param_required?
      native_params = %i[shop hmac timestamp locale protocol return_to]
      request.path != '/' || sanitized_params.except(*native_params).any?
    end

    def fullpage_redirect_to(url)
      if ShopifyApp.configuration.embedded_app?
        render('shopify_app/shared/redirect', layout: false,
               locals: { url: url, current_shopify_domain: current_shopify_domain })
      else
        redirect_to(url)
      end
    end

    def sanitized_shop_name
      @sanitized_shop_name ||= sanitize_shop_param(params)
    end

    def referer_sanitized_shop_name
      return unless request.referer.present?

      @referer_sanitized_shop_name ||= begin
        referer_uri = URI(request.referer)
        query_params = Rack::Utils.parse_query(referer_uri.query)

        sanitize_shop_param(query_params.with_indifferent_access)
      end
    end

    def sanitize_shop_param(params)
      return unless params[:shop].present?
      ShopifyApp::Utils.sanitize_shop_domain(params[:shop])
    end

    def sanitized_params
      request.query_parameters.clone.tap do |query_params|
        if params[:shop].is_a?(String)
          query_params[:shop] = sanitize_shop_param(params)
        end
      end
    end

    # TODO: Where is this used? Is this part of another API?
    def return_address
      session.delete(:return_to) || ShopifyApp.configuration.root_url
    end
  end
end