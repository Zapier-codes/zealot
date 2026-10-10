# frozen_string_literal: true

Rails.application.routes.draw do
  root to: 'home#index'
  get 'dashboard', to: 'dashboards#index', as: :dashboard

  # Z-P23 (Play Console parity): the console as an installable web app. The manifest is read before a
  # session exists and the service worker sits outside the page, so both are plain GETs. `format: false`
  # keeps `.webmanifest` / `.js` in the path rather than being parsed as a response format.
  get 'manifest.webmanifest', to: 'pwa#manifest', as: :pwa_manifest, format: false
  get 'service-worker.js', to: 'pwa#service_worker', as: :pwa_service_worker, format: false

  # Z-P10 / Task 50: the publisher's revenue report and the payout actions on it.
  resource :revenue, only: :show, controller: 'revenues'
  resources :payouts, only: %i[create] do
    member do
      post :cancel
      post :refresh
    end
  end

  # Email preferences: reached from a link in every automated email, no login
  # needed (the signed token identifies the user).
  get   'email_preferences/:token', to: 'email_preferences#show',   as: :email_preferences
  patch 'email_preferences/:token', to: 'email_preferences#update'

  # Task 32: inbound B-PAY (Hyperswitch) webhook. Top-level, not under
  # `namespace :api`, because it's signature-authenticated server-to-server
  # (HyperswitchWebhooksController), not user-token authenticated like the
  # rest of that namespace — same reasoning as email_preferences above
  # being outside any auth-required scope.
  post 'hooks/hyperswitch', to: 'hyperswitch_webhooks#create'
  # Task 45g: the signed catalog index served from this host (exact stored bytes; see CatalogController).
  get 'catalog/index.json', to: 'catalog#index', format: false
  get 'catalog/index.json.sig', to: 'catalog#signature', format: false
  # Task 47d: the newest installable version of one package (the injected updater's check). The constraint lets
  # the dots of a package name through (a segment stops at a dot otherwise); the lookup validates the name again.
  get 'catalog/updates/:package_name', to: 'catalog#latest', format: false,
                                       constraints: { package_name: /[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+/ }
  # Task 42i: hosted card page for one listing-fee payment; the signed token in the link is the only credential.
  get 'checkout/:token', to: 'checkouts#show', as: :store_listing_checkout, constraints: { token: %r{[^/]+} }

  #############################################
  # Z-P9 (principle 2): anonymous reviews. Public, no account and no session. A client (or the website)
  # first asks for a proof-of-work challenge, then posts the solved review, optionally signed by a
  # device-bound key that was registered up front. See AnonymousReviewsController.
  #############################################
  get  'reviews/:package_name/challenge', to: 'anonymous_reviews#challenge',
       as: :anonymous_review_challenge, format: false,
       constraints: { package_name: /[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+/ }
  # Register a device-bound key (its attestation chain is checked here) so a later review can carry the
  # "verified install" mark. No key required to review; this only earns the mark.
  post 'reviews/:package_name/keys', to: 'anonymous_reviews#register_key',
       as: :anonymous_review_keys, format: false,
       constraints: { package_name: /[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+/ }
  post 'reviews/:package_name', to: 'anonymous_reviews#create',
       as: :anonymous_reviews, format: false,
       constraints: { package_name: /[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+/ }

  #############################################
  # User
  #############################################
  # There is no separate sign-up page: the login form registers unknown emails
  # (see Users::SessionsController#create). Devise's registration routes are
  # therefore skipped, and only the profile-management ones (edit / update /
  # cancel account) are mounted again below with the same helper names.
  devise_for :users, controllers: {
    sessions: 'users/sessions',
    registrations: 'users/registrations',
    confirmations: 'users/confirmations',
    omniauth_callbacks: 'users/omniauth_callbacks',
  }, skip: %i[unlocks registrations]

  devise_scope :user do
    resource :registration, only: %i[edit update destroy], path: 'users',
                            controller: 'users/registrations', as: :user_registration
  end

  #############################################
  # App
  #############################################
  resources :apps do
    member do
      get :new_owner
      put :update_owner
    end

    collection do
      resources :archives, only: %i[index update destroy], path: 'archived', module: :apps, as: 'archived_apps'
    end

    resources :collaborators, except: %i[index show]

    # Task 27d-e2-a: add and remove store-listing graphics; the panel that calls them is on the app page (27d-e2-b).
    # Task 27d-e2-d: set or clear the promo video (PATCH /apps/:app_id/promo_video).
    resource :promo_video, only: :update, module: :apps
    # Task 34a-7: the owner creates, lists and revokes the app's API tokens (a session page, never /api).
    resources :api_tokens, only: %i[index create destroy], module: :apps
    # Task 27e-c: the store-listing text editor (name, short description, full description). It stages a
    # draft (ListingEditService); nothing on the live listing changes until the owner publishes (27e-d).
    # Task 27e-d: publish (POST .../listing_text/commit) or discard (DELETE) the draft.
    resource :listing_text, only: %i[show update destroy], module: :apps do
      post :commit
    end
    # Z-P5/Z-P6: the "App content" section — the content/age rating, the Data Safety answers, the two store
    # flags and the store privacy-policy URL. Same staged-draft model as listing_text above (GET the form,
    # PATCH stages, POST commit publishes, DELETE discards); the reviewer-access instructions on the same
    # page are backend-only and save straight to the app (see Apps::AppContentsController for why).
    resource :app_content, only: %i[show update destroy], module: :apps do
      post :commit
    end
    # Z-P21: machine translation of the listing. The index publishes only approved, non-stale translations.
    get 'listing_translations', to: 'apps/listing_translations#show', as: :listing_translations
    post 'listing_translations/translate', to: 'apps/listing_translations#translate', as: :translate_listing_translations
    post 'listing_translations/:locale/review', to: 'apps/listing_translations#review', as: :review_listing_translation
    delete 'listing_translations/:locale', to: 'apps/listing_translations#destroy', as: :listing_translation
    # Z-P8: the reviews inbox — read an app's reviews and write the developer reply (one per review).
    resources :reviews, only: %i[index update], module: :apps
    # Z-P9: moderate anonymous reviews the automated moderator held for a person (publish / reject).
    resources :anonymous_reviews, only: %i[index], module: :apps do
      member do
        post :publish
        post :reject
      end
    end
    # Z-P22: the deep-link verification checker — read the app's declared hosts and check each one's
    # /.well-known/assetlinks.json against the app's package + signing certificate.
    resource :deep_link_verification, only: :show, module: :apps
    # Z-P2/Z-P3/Z-P4: the automated-review policy status — the machine verdict on every release, shown per app.
    resource :policy_status, only: :show, module: :apps
    resources :listing_graphics, only: %i[create update destroy], module: :apps do
      # Task 27d-e2-c: move a screenshot up or down one place (params: direction=up|down).
      member { patch :move }
    end

    # Task 25: the app's store listing (draft -> awaiting payment -> live).
    resource :store_listing, only: %i[show create], module: :apps do
      patch :mark_paid
      # Task 32: the real payment path — creates a Payment and starts a
      # B-PAY checkout. See Apps::StoreListingsController#pay.
      post :pay
    end

    resources :schemes, except: %i[show] do
      resources :channels, except: %i[index show]
    end

    resources :debug_files, only: [] do
      collection do
        get ':device', action: :device, as: :device
      end
    end
  end

  # Task 25: how the signed-in user publishes on our own stores
  # (Individual / Company).
  resource :publisher_profile, only: %i[new create edit update]

  resources :channels, only: %i[index show] do
    member do
      delete :destroy_releases
    end

    resources :web_hooks, only: %i[new create destroy] do
      member do
        get :enable
        get :disable
        get 'test/:event', to: 'web_hooks#test', as: :test
      end
    end

    # Task 40h-b: direct-to-storage upload (session, then finalize). JSON only; 404 until enabled.
    resources :release_uploads, only: :create do
      member do
        post :finalize
        # Task 40s-c: parts of a multipart upload (sign a batch, list what R2 holds).
        post :parts, action: :sign_parts
        get :parts, action: :list_parts, as: :list_parts
      end
    end

    resources :releases, path_names: { new: 'upload' } do
      # Task 27f-b: PATCH /channels/:channel_id/releases/:id/status (hold, release, halt, pull ...).
      member do
        patch :status, action: :update_status
      end

      scope module: :releases do
        get :install, to: 'install#show'
      end

      scope module: :releases do
        get 'qrcode(/:size)(/:theme)', to: 'qrcode#show', as: :qrcode, defaults: {
          size: 'md',
          theme: 'light',
          format: 'png'
        }
      end

      member do
        post :auth
      end

      # Z-P11 (Play Console parity): a release's mapping / native symbol uploads. Upload and replace
      # are `create` (one row per kind is enforced by the model), so only :create, :destroy and the
      # per-release list are exposed.
      resources :debug_symbols, only: %i[index create destroy]
    end

    scope module: :channels do
      resources :versions, only: %i[index show destroy], constraints: { id: /(.+)+/ }
      resources :branches, only: %i[index destroy], constraints: { id: /(.+)+/ }
      resources :release_types, only: %i[index destroy], constraints: { id: /(.+)+/ }
    end
  end

  #############################################
  # Debug File
  #############################################
  resources :debug_files do
    member do
      post :reprocess
    end
  end

  #############################################
  # Teardown
  #############################################
  resources :teardowns, except: %i[edit update], path_names: { new: 'upload' }

  #############################################
  # Download
  #############################################
  namespace :download do
    resources :releases, only: :show do
      member do
        # Task 27d-b: must stay above ':filename' (which matches anything) or `icon` is read as a filename.
        get :icon, action: :icon
        # Z-P13: a File-by-File update delta, named by the version it patches from.
        get :delta, action: :delta
        get ':filename', action: :download, filename: /.+/, as: 'filename'
      end
    end

    resources :debug_files, only: :show do
      member do
        get ':filename', action: :download, filename: /.+/, as: 'filename'
      end
    end

    # Z-P11 (Play Console parity): fetch a release's mapping / native symbol file.
    resources :debug_symbols, only: :show do
      member do
        get ':filename', action: :download, filename: /.+/, as: 'filename'
      end
    end

    # Task 27d-d2-d: a store-listing graphic (screenshot or feature graphic), served by id.
    resources :graphics, only: :show
  end

  #############################################
  # UDID (iOS/iPadOS/arm chip macOS)
  #############################################
  resources :udid, as: :udid, param: :udid, only: %i[ index show edit update ] do
    collection do
      get 'qrcode(/:size)(/:theme)', action: :qrcode, as: :qrcode, defaults: {
        size: 'xl',
        theme: 'light',
        format: 'png'
      }
      # get :qrcode
      get :install
      post :retrieve, action: :create
    end

    member do
      post :register
    end
  end

  #############################################
  # Admin
  #############################################
  # Signed out: /admin is the (same) login page, marked as the admin entry —
  # the only place the admin account can be created. Signed in, this constraint
  # steps aside and the admin namespace below serves /admin (404 for non-admins).
  devise_scope :user do
    get 'admin', to: 'users/sessions#new', as: :admin_entry,
                 defaults: { admin_entry: '1' },
                 constraints: ->(request) { !request.env['warden']&.authenticate?(scope: :user) }
  end

  authenticate :user, ->(user) { user.admin? } do
    namespace :admin do
      root to: 'settings#index'

      resources :settings
      resources :users, except: :show do
        member do
          put :lock
          put :resend_confirmation
          delete :unlock
        end
      end
      resources :web_hooks, except: %i[ show new create ] do
        member do
          # Z-P19: mint a Standard Webhooks signing secret for this hook (shows it once).
          post :signing_secret, action: :rotate_signing_secret
        end
      end
      resources :apple_teams, only: %i[ edit update ]
      resources :background_jobs, only: :index
      resources :system_info, only: :index
      resources :database_analytics, only: :index
      # Z-P16: the reports surface — which self-hostable site-view tool is live, and links out to the
      # operator's BI tool (Metabase/Superset) over Zealot's Postgres.
      resources :reports, only: :index
      # Task 31b: read-only view of D-store-owned figures (see DstoreStats).
      resources :dstore_stats, only: :index
      # Z-P18 (audit-log slice): the append-only audit log (Play Console's "changes log"). Read-only here; written by the
      # code that makes each change.
      resources :audit_entries, only: :index

      # Z-P18 (SCIM half): the tokens an identity provider uses to provision people (ScimToken). A platform
      # admin mints, lists and revokes them; the secret is shown once at creation and never again.
      resources :scim_tokens, only: %i[ index create destroy ]

      # Z-P18 (SSO/SAML half): the SAML sign-in status and the SP metadata the operator pastes into the IdP
      # (the `metadata` action renders the XML; the show page is the panel).
      resource :saml, only: :show, controller: 'saml_settings' do
        get :metadata
      end
      resources :apple_keys, except: %i[ edit update ] do
        member do
          put :sync_devices
          get :private_key
        end
      end

      # Org-wide (task #5) — singular resource, not resources: there is at
      # most one AndroidSigningKey record. See AndroidSigningKey#current.
      resource :android_signing_key, except: %i[ edit update ]

      # Play Store publish-approval queue (task #11). Acts on Release
      # records that have play_store_target set, not a model of its own —
      # see Admin::PlayApprovalsController.
      resources :play_approvals, only: %i[ index ] do
        member do
          put :approve
          put :reject
        end
      end

      # Task 31a (item 4): editorial flags an app's own owner cannot set on
      # themselves -- see Admin::AppsController and AppPolicy#set_editorial_flags?.
      # Deliberately not a full `resources :apps`: an admin manages an app's
      # own fields (name, category, etc.) through the top-level, non-admin
      # `resources :apps` further down this file.
      resources :apps, only: %i[ index ] do
        member do
          put :toggle_featured
          put :toggle_editors_pick
        end
      end

      # Task 31a (item 4): the `collections[]` top-level registry
      # CatalogIndex::Serializer#serialize_collections already publishes.
      # Task 37b-ii-t3: white-label tenants. No destroy until 37b-iii defines what deleting a
      # tenant does to its apps and keys; no show (the edit page is the detail page).
      resources :tenants, only: %i[ index new create edit update ] do
        # Task 37b-ii-k6: the tenant signing-key lifecycle (generate, stage_next, promote,
        # retire), POST only. There is no index/show/destroy: the panel on the tenant's edit page
        # is the only view, and a key leaves the system by being retired.
        resource :key, only: [], controller: 'tenant_keys' do
          post :generate
          post :stage_next
          post :promote
          post :retire
        end

        # Task 37b-iii-s7c-7: who may sign in to this tenant's console (`tenant_memberships`).
        # POST/PATCH/DELETE only: the panel on the tenant's edit page is the only view.
        resources :memberships, only: %i[ create update destroy ], controller: 'tenant_memberships'
      end

      resources :collections do
        member do
          post :add_app
          delete :remove_app
        end
      end

      # Task 31a (item 4): dated sponsored-placement windows, one per app
      # per window -- see SponsoredSlot and #sponsored_slots_for.
      resources :sponsored_slots, except: %i[ show ]

      # Task #7: two deliberately separate org-wide singletons — the key
      # that signs an AAB for Play (PlayUploadKey) and the credential that
      # authenticates the API call that uploads it (PlayCredential). See
      # both models' comments for why these aren't merged with each other
      # or with AndroidSigningKey above.
      resource :play_upload_key, except: %i[ edit update ]
      resource :play_credential, except: %i[ edit update ]

      resources :logs, only: %i[ index ] do
        collection do
          get :retrive
        end
      end

      resources :backups do
        collection do
          get :parse_schedule
        end

        member do
          post :enable
          post :disable
          post :perform
          # get :job, action: :refresh_job
          delete :job, action: :cancel_job
          get :archive, action: :download_archive
          delete :archive, action: :destroy_archive
        end
      end

      resources :services, only: [] do
        collection do
          # zealot service
          post :restart
          get :status
          # smtp
          post :smtp_verify
        end
      end

      mount GoodJob::Engine, at: 'jobs', as: :jobs
      mount PgHero::Engine, at: 'pghero', as: :pghero
    end
  end

  #############################################
  # Misc
  #############################################
  resources :modals, only: :show, param: :type, constraints: { type: /[a-z0-9\-_]+/ }

  #############################################
  # API v1
  #############################################
  health_check_routes

  # Z-P18 (SCIM half, Play Console parity): the SCIM 2.0 provisioning API an identity provider calls.
  # Authenticated by a bearer `ScimToken` (`Authorization: Bearer zsc_...`) ONLY, and the token decides the
  # tenant. `Scim::UsersController` owns the resources; the three discovery documents live on the same
  # controller. `defaults: { format: :json }` keeps a client that omits the suffix on the JSON path.
  namespace :scim, path: 'scim/v2', defaults: { format: :json } do
    resources :users, only: %i[index show create update destroy], controller: 'users'
    get 'ServiceProviderConfig', to: 'users#service_provider_config'
    get 'Schemas', to: 'users#schemas'
    get 'ResourceTypes', to: 'users#resource_types'
  end

  namespace :api do
    resources :users, except: %i[new edit] do
      collection do
        get :me
        get :search
      end

      member do
        post :lock
        delete :unlock
        # Task 42j: a platform admin reads any account's API token.
        get :token
      end

      # Task 42j: a platform admin's view of any account's publisher profile.
      resource :publisher_profile, only: %i[show update], controller: 'publisher_profiles'
    end

    # Task 42j: the token's own publisher profile.
    resource :publisher_profile, only: %i[show update], controller: 'publisher_profiles'

    resources :apps, except: %i[new edit] do
      collection do
        post :upload, to: 'apps/upload#create'

        # Task 40h-b: direct-to-storage upload (session, then finalize); user token or per-app token.
        post :upload_sessions, to: 'apps/upload_sessions#create'
        post 'upload_sessions/:id/finalize', to: 'apps/upload_sessions#finalize', as: :finalize_upload_session
        # Task 40h-c-2: the outcome of an upload, polled by the CI that opened it.
        get 'upload_sessions/:id', to: 'apps/upload_sessions#show', as: :upload_session
        # Task 40s-c: parts of a multipart upload (sign a batch, list what R2 holds).
        post 'upload_sessions/:id/parts', to: 'apps/upload_sessions#sign_parts', as: :sign_upload_session_parts
        get 'upload_sessions/:id/parts', to: 'apps/upload_sessions#list_parts', as: :list_upload_session_parts

        get :latest, to: 'apps/latest#show'
        get :version_exist, to: 'apps/version_exist#show'
        get :versions, to: 'apps/versions#index'
        get 'versions/(:release_version)', to: 'apps/versions#show'
      end

      resources :schemes, except: %i[new edit], shallow: true do
        resources :channels, except: %i[new edit]
      end

      resources :collaborators, param: :user_id, except: %i[index new edit]

      # Task 34a-3: the listing text over the API (stage, publish, discard); user token or per-app token.
      resource :listing_edit, only: %i[show update destroy], controller: 'apps/listing_edits' do
        post :commit
      end

      # Task 43a: the store-listing graphics over the API (list, add, remove); user token or per-app token.
      resources :listing_graphics, only: %i[index create destroy], controller: 'apps/listing_graphics' do
        collection do
          # Task 32 (D-Store leaf 7.a.vii.zi): PUT the feature graphic, replacing it in place.
          put :feature_graphic, to: 'apps/listing_graphics#replace_feature_graphic'
          # Task 33 (D-Store leaf 7.a.vii.zo): PUT the whole ordered set of screenshots in one call.
          put :screenshots, to: 'apps/listing_graphics#replace_screenshots'
        end
      end

      # Task 43f-3: the app's store icon over the API (PUT replaces it on the newest catalog release).
      resource :listing_icon, only: :update, controller: 'apps/listing_icons'

      # Task 34d-2: create, list and revoke the app's per-app API tokens. User token in the Authorization
      # header ONLY; a per-app token can never open this (decision 34-4). See Api::Apps::ApiTokensController.
      resources :api_tokens, only: %i[index create destroy], controller: 'apps/api_tokens'

      # Task 42e: the store listing, the owner and the editorial flags over the API (user token only), so
      # everything the console does to put an app in D-Store can be scripted. See the controllers' headers.
      resource :store_listing, only: %i[show create], controller: 'apps/store_listings' do
        patch :mark_paid
        # Task 42f: start the B-PAY listing-fee payment (owner) and read its status.
        post :pay
        get :payment
      end
      resource :owner, only: :update, controller: 'apps/owners'
      resource :editorial, only: :update, controller: 'apps/editorials'
      # Task 45a: PUT/GET /api/apps/:app_id/migrated_stats (platform admin, user token only).
      resource :migrated_stats, only: %i[show update], controller: 'apps/migrated_stats'
      # Task 45f: GET/PUT /api/apps/:app_id/catalog_basics (category and package name; platform admin, user token only).
      resource :catalog_basics, only: %i[show update], controller: 'apps/catalog_basics'
      # Task 47e: GET/PUT /api/apps/:app_id/updater (the publisher's switch for the injected updater; user token).
      resource :updater, only: %i[show update], controller: 'apps/updater'
      # Task 45c: GET/POST /api/apps/:app_id/migrated_comments, DELETE .../:id (platform admin, user token only).
      resources :migrated_comments, only: %i[index create destroy], controller: 'apps/migrated_comments'
    end
    resources :releases, only: %i[show update destroy] do
      # Task 34a-6: POST /api/releases/:id/release (held -> available; user token or per-app token).
      member do
        post :release
        # Task 40q: POST /api/releases/:id/retry_compile (platform admin, user token only).
        post :retry_compile
        # Task 44f: POST /api/releases/:id/rename_stored (platform admin, user token only).
        post :rename_stored
        # Task 46b: PUT /api/releases/:id/permissions (replace the permission list; user token).
        put :permissions
        # Task 46c: POST /api/releases/:id/supersede_previous (remove the older releases of the channel; user token).
        post :supersede_previous
        # Z-P11 (Play Console parity): upload / replace a release's mapping or native symbol file.
        # See Api::DebugSymbolsController.
        post 'debug_symbols', to: 'debug_symbols#create'
      end
    end

    # Task #7: token-authenticated, admin-only mirror of the admin-namespace
    # singleton (config/routes.rb line ~203). See Api::PlayCredentialsController
    # and PlayCredentialPolicy for why admin-only is enforced explicitly here
    # rather than relying on routing-level gating the way the admin namespace does.
    resource :play_credential, only: %i[ show create destroy ]

    # Task 34d-1: the org-wide Android signing key, platform-admin only, user token in the Authorization
    # header ONLY. See Api::AndroidSigningKeysController and AndroidSigningKeyPolicy.
    resource :android_signing_key, only: %i[ show create destroy ]

    # Task 19f: token-authenticated, admin-only interface between Rails and
    # the GitHub Actions Telegram-archive batch (mtproto-worker/src/archive_batch.ts).
    # See Api::MtprotoArchiveController and MtprotoArchivePolicy.
    get 'mtproto_archive/candidates', to: 'mtproto_archive#candidates'
    post 'mtproto_archive/:id/complete', to: 'mtproto_archive#complete'

    # Task 40a: the storage repo's compile workflow reports its result here. NOT a user or app-token
    # route: authenticated by the shared CI_COMPILE_CALLBACK_TOKEN only. See Api::CiCompileController.
    post 'ci_compile/:id/callback', to: 'ci_compile#callback'
    # Z-P12: the pre-launch workflow reports the redroid run's JSON payload here. Same shared-secret door,
    # PRE_LAUNCH_CALLBACK_TOKEN. See Api::PreLaunchReportsController.
    post 'pre_launch_reports/:id', to: 'pre_launch_reports#create'
    get 'tenant_builds/:build_id/download', to: 'tenant_builds#download', as: :tenant_build_download

    # Task 40i-a: the stage-1 workflow reports what it read from a staged upload. Authenticated by GitHub's OIDC
    # token only (GithubOidcVerifier); creates no release. See Api::ReleaseUploadCallbacksController.
    post 'release_uploads/:id/stage1', to: 'release_upload_callbacks#stage1'
    # Task 40i-c: the same workflow's second report (files uploaded, bundle built). Same OIDC door; it updates the
    # release stage 1 made and creates none. See ReleaseUploadFinisher.
    post 'release_uploads/:id/stage2', to: 'release_upload_callbacks#stage2'

    resources :debug_files, except: %i[new edit create] do
      collection do
        post :upload, action: :create
        get :download, to: 'debug_files/download#show'

        get 'exists/version', to: 'debug_files/exists#version'
        get 'exists/binary', to: 'debug_files/exists#binary'
        get 'exists/uuid', to: 'debug_files/exists#uuid'
      end
    end

    resources :devices, only: %i[update]
    resources :version, only: :index

    if Setting.show_footer_openapi_endpoints
      mount Rswag::Api::Engine => '/swagger', as: :openapi
      mount Rswag::Ui::Engine => '/swagger', as: :openapi_ui
    end

    match '*unmatched_route', via: :all, to: 'base#raise_not_found', format: :json
  end

  #############################################
  # API v2
  #############################################
  post '/graphql', to: 'graphql#execute'

  #############################################
  # Development Only
  #############################################
  if Rails.env.development?
    mount LetterOpenerWeb::Engine, at: '/tools/inbox'
    mount GraphiQL::Rails::Engine, at: "/tools/graphiql", graphql_path: "/graphql"
  end

  ############################################
  # URL Friendly
  ############################################
  scope path: ':channel', format: false, as: :friendly_channel do
    get '/overview', to: 'channels#show'
    get '', to: 'releases#index', as: 'releases'
    get 'versions', to: 'channels/versions#index', as: 'versions'
    get 'versions/:name', to: 'channels/versions#show', name: /(.+)+/, as: 'version'
    delete 'versions/:name', to: 'channels/versions#destroy', name: /(.+)+/
    get 'release_types/:name', to: 'channels/release_types#index', name: /(.+)+/, as: 'release_types'
    delete 'release_types/:name', to: 'channels/release_types#destroy', name: /(.+)+/
    get 'branches/:name', to: 'channels/branches#index', name: /(.+)+/, as: 'branches'
    delete 'branches/:name', to: 'channels/branches#destroy', name: /(.+)+/
    get ':id', to: 'releases#show', as: 'release'
    # get ':id/download', to: 'download/releases#show', as: 'channel_release_download'
  end

  match '/', via: %i[post put patch delete], to: 'application#raise_not_found', format: false
  match '*unmatched_route', via: :all, to: 'application#raise_not_found', format: false
end
