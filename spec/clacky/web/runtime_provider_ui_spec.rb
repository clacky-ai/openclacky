# frozen_string_literal: true

RSpec.describe "Runtime provider WebUI" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:index) { File.read(File.join(web_dir, "index.html")) }
  let(:runtime_store) { File.read(File.join(web_dir, "features/model-tester/store.js")) }
  let(:onboard) { File.read(File.join(web_dir, "components/onboard.js")) }
  let(:settings) { File.read(File.join(web_dir, "settings.js")) }
  let(:model_picker) { File.read(File.join(web_dir, "components/model-picker.js")) }
  let(:new_session_store) { File.read(File.join(web_dir, "features/new-session/store.js")) }
  let(:new_session) { File.read(File.join(web_dir, "features/new-session/view.js")) }
  let(:sessions) { File.read(File.join(web_dir, "sessions.js")) }
  let(:skills) { File.read(File.join(web_dir, "skills.js")) }
  let(:app_css) { File.read(File.join(web_dir, "app.css")) }
  let(:i18n) { File.read(File.join(web_dir, "i18n.js")) }

  def function_source(source, name)
    source[/\b(?:async\s+)?function\s+#{Regexp.escape(name)}\b.*?(?=\n  (?:async\s+)?function\s+|\n\}\)\(\);)/m]
  end

  describe "provider-neutral runtime helper" do
    it "detects runtime providers from descriptor metadata and never branches on Codex" do
      expect(runtime_store).to include('provider.auth_mode === "runtime"')
      expect(runtime_store).to include("provider.runtime_id")
      expect(runtime_store).not_to match(/provider\.id\s*===\s*["']codex["']/)
    end

    it "routes status and authentication through the contributing extension id" do
      expect(runtime_store).to include('provider.extension_id')
      expect(runtime_store).to include('`/api/ext/${encodeURIComponent(provider.extension_id)}/${action}`')
      expect(runtime_store).not_to include('`/api/ext/${encodeURIComponent(provider.runtime_id)}/${action}`')
      expect(runtime_store).to include('runtimeRequest(provider, "status"')
      expect(runtime_store).to include('runtimeRequest(provider, "authenticate"')
      expect(runtime_store).to include('runtimeRequest(provider, "discover", { method: "POST" })')
    end

    it "bounds login polling and stops on connected, rejected, error, or timeout states" do
      poll = function_source(runtime_store, "pollStatus")
      expect(poll).to include("maxAttempts")
      expect(poll).to match(/attempt\s*<\s*maxAttempts/)
      expect(poll).to include("view.terminal")
      expect(poll).to include('state: "timeout"')
      expect(poll).to include("shouldContinue")
      expect(poll).to include("cancelled: true")
    end

    it "treats a dormant runtime as a neutral terminal state rather than a logged-out account" do
      status_view = function_source(runtime_store, "statusView")
      expect(status_view).to include('status === "idle"')
      expect(status_view).to include('state: "idle"')
      expect(status_view).to match(/state:\s*"idle".*?terminal:\s*true/)
    end

    it "keeps browser-login polling longer than the runtime authentication deadline" do
      expect(runtime_store).to include("const AUTH_POLL_ATTEMPTS = 305")
      expect(function_source(onboard, "_authenticateSetupRuntime"))
        .to include("maxAttempts: RuntimeProvider.AUTH_POLL_ATTEMPTS")
      expect(function_source(settings, "_authenticateModalRuntime"))
        .to include("maxAttempts: RuntimeProvider.AUTH_POLL_ATTEMPTS")
    end
  end

  describe "shared form contract" do
    it "provides API-field groups and runtime status panels in both existing forms" do
      %w[
        model-modal-model-field model-modal-api-fields model-modal-runtime-panel
        model-modal-runtime-status model-modal-runtime-login model-modal-runtime-recheck
        setup-model-field setup-api-fields setup-runtime-panel setup-runtime-status
        setup-runtime-login setup-runtime-recheck
      ].each do |id|
        expect(index).to include(%(id="#{id}")), "missing ##{id}"
      end
    end

    it "ships connection states, actions, dynamic model guidance, and ChatGPT name in both languages" do
      %w[
        provider.name.codex runtime.provider.status.checking
        runtime.provider.status.connected runtime.provider.status.notConnected
        runtime.provider.status.idle runtime.provider.status.starting
        runtime.provider.status.unavailable
        runtime.provider.status.timeout runtime.provider.connect
        runtime.provider.recheck runtime.provider.dynamicHint
        runtime.provider.newSessionHint
        sib.reasoning.minimal sib.reasoning.ultra
      ].each do |key|
        expect(i18n.scan(%("#{key}")).length).to be >= 2, "missing bilingual key #{key}"
      end
      expect(i18n.scan('"provider.name.codex":         "ChatGPT"').length).to eq(2)
    end

    it "does not hide runtime providers behind API-key-only onboarding copy" do
      expect(index).to include("Choose another provider (API or ChatGPT)")
      expect(i18n).to include('"onboard.manual.toggle":      "Choose another provider (API or ChatGPT)"')
      expect(i18n).to include('"onboard.manual.toggle":      "选择其他服务商（API 或 ChatGPT）"')
    end
  end

  describe "first-run onboarding" do
    it "tracks the selected provider by id and toggles API fields from runtime metadata" do
      sync = function_source(onboard, "_syncSetupProviderMode")
      expect(onboard).to include("let _selectedProviderId")
      expect(onboard).to include("p.id === _selectedProviderId")
      expect(sync).to include("RuntimeProvider.isRuntimeProvider(provider)")
      expect(sync).to include('"setup-api-fields"')
      expect(sync).to include('"setup-runtime-panel"')
      expect(sync).to include("input.readOnly = true")
    end

    it "requires a discovered default model without API credentials or the API model tester" do
      save = function_source(onboard, "_saveRuntimeProvider")
      expect(save).to include("RuntimeProvider.discover(provider)")
      expect(save).to include("provider_id: provider.id")
      expect(save).to include("display_model: selectedModel")
      expect(save).to include('type: "default"')
      expect(save).not_to include("base_url:")
      expect(save).not_to include("api_key:")
      expect(save).not_to include("ModelTester.testConnection")
    end

    it "connects explicitly before polling passive status" do
      refresh = function_source(onboard, "_refreshSetupRuntimeStatus")
      expect(refresh).to include("RuntimeProvider.connect(provider)")
      expect(refresh).to include("RuntimeProvider.discover(provider)")
      expect(runtime_store).to include('runtimeRequest(provider, "connect", { method: "POST" })')
    end

    it "completes onboarding and opens its session without sending the onboard skill to runtimes" do
      save = function_source(onboard, "_saveRuntimeProvider")
      launch = function_source(onboard, "_launchOnboardSession")
      expect(save).to include("_launchOnboardSession({ personalize: false")
      expect(launch).to include("await _complete()")
      expect(launch).to include("_createSetupSession(modelId)")
      expect(launch).to match(/if \(personalize\).*?Sessions\.startWith\(`\/onboard/m)
    end

    it "restores ordinary API fields and clears hidden credentials after leaving runtime mode" do
      select = function_source(onboard, "_selectSetupProvider")
      clear = function_source(onboard, "_clearSetupApiFields")
      expect(select).to include("previousWasRuntime")
      expect(select).to include("nextIsRuntime")
      expect(select).to include("previousProviderId")
      expect(select).to include("providerChanged")
      expect(select).to include("_clearSetupApiFields()")
      expect(clear).to include('$("setup-api-key").value = ""')
      expect(select).to include("_syncSetupProviderMode(provider)")
    end

    it "keeps login retryable and invalidates saves when the provider changes" do
      render = function_source(onboard, "_renderSetupRuntimeStatus")
      save = function_source(onboard, "_saveRuntimeProvider")
      expect(render).to include("data.can_authenticate !== false")
      expect(render).to include("recheck.disabled")
      expect(onboard).to include("let _providerOperationRequest")
      expect(save).to include("operation !== _providerOperationRequest")
    end

    it "locks every setup form control while a provider test or save is in flight" do
      busy = function_source(onboard, "_setSetupProviderBusy")
      render = function_source(onboard, "_renderSetupRuntimeStatus")
      expect(busy).to include('querySelectorAll("input, button, select, textarea")')
      expect(busy).to include("control.disabled = true")
      expect(busy).to include("data-provider-operation-disabled")
      expect(busy).to include('trigger.setAttribute("aria-disabled"')
      expect(busy).to include('setAttribute("aria-busy"')
      expect(render).to include("_providerOperationInFlight")
    end
  end

  describe "Settings model cards" do
    it "keeps the current default checked until another card is promoted" do
      open_modal = function_source(settings, "_openModal")
      expect(open_modal).to include('model.type === "default"')
      expect(open_modal).to include("setDefaultCb.disabled")
      expect(open_modal).to match(
        /setDefaultCb\.disabled\s*=\s*isOnlyModel\s*\|\|\s*isCurrentDefault/
      )
    end

    it "resolves modal runtime behavior from the selected provider id before URL matching" do
      selected = function_source(settings, "_selectedModalProvider")
      expect(selected).to include("_modalSelectedProviderId")
      expect(selected).to match(/_providers\.find\(.*\.id\s*===\s*_modalSelectedProviderId/)
      expect(selected).not_to include("base_url")
    end

    it "uses the existing card actions and runtime health test" do
      test_model = function_source(settings, "_testModel")
      %w[edit test delete default duplicate].each do |action|
        expect(settings).to include(%(case "#{action}"))
      end
      expect(test_model).to include("RuntimeProvider.isRuntimeProvider(provider)")
      expect(test_model).to include("ModelTester.testRuntime")
    end

    it "saves runtime cards with the discovered default model and ordinary metadata" do
      save = function_source(settings, "_saveRuntimeModalModel")
      expect(save).to include("provider_id: provider.id")
      expect(save).to include("display_model: selectedModel")
      expect(save).to include("remark")
      expect(save).to include("type")
      expect(save).not_to include("base_url:")
      expect(save).not_to include("api_key:")
    end

    it "clears hidden API values across runtime boundaries and shows them again for API providers" do
      select = function_source(settings, "_selectModalProvider")
      sync = function_source(settings, "_syncModalProviderMode")
      expect(select).to include("previousWasRuntime !== nextIsRuntime")
      expect(select).to include("previousProviderId")
      expect(select).to include("providerChanged")
      expect(select).to include("_clearModalApiFields()")
      expect(sync).to include('"model-modal-api-fields"')
      expect(sync).to include('"model-modal-runtime-panel"')
      expect(sync).to include("input.readOnly = true")
    end

    it "invalidates an in-flight save or login status refresh after provider changes" do
      save = function_source(settings, "_saveRuntimeModalModel")
      render = function_source(settings, "_renderModalRuntimeStatus")
      expect(settings).to include("let _modelSaveRequest")
      expect(save).to include("operation !== _modelSaveRequest")
      expect(render).to include("recheck.disabled")
    end

    it "locks the full modal and guards delayed success close by modal context" do
      busy = function_source(settings, "_setModalSaveBusy")
      close = function_source(settings, "_closeModal")
      delayed_close = function_source(settings, "_scheduleModalSaveClose")
      runtime_save = function_source(settings, "_saveRuntimeModalModel")
      api_save = function_source(settings, "_saveModalModel")

      expect(busy).to include('querySelectorAll("input, button, select, textarea")')
      expect(busy).to include("control.disabled = true")
      expect(busy).to include("data-model-save-disabled")
      expect(busy).to include('trigger.setAttribute("aria-disabled"')
      expect(busy).to include('setAttribute("aria-busy"')
      expect(close).to include("if (_modelSaveInFlight && force !== true) return")
      expect(delayed_close).to include("operation !== _modelSaveRequest")
      expect(delayed_close).to include("_modalProviderKey() !== providerKey")
      expect(delayed_close).to include("currentIndex !== index")
      expect(delayed_close).to include('modal.style.display === "none"')
      expect(runtime_save).to include("_scheduleModalSaveClose(operation, provider.id, index)")
      expect(api_save).to include("_scheduleModalSaveClose(operation, selectedProviderKey, index)")
    end

    it "keeps runtime identity immutable and renders connection status on each card" do
      changed = function_source(settings, "_modalProviderKindChanged")
      card_status = function_source(settings, "_refreshRuntimeCardStatus")
      expect(changed).to include("provider_id !== provider.id")
      expect(settings).to include("_refreshRuntimeCardStatus(provider, model, index)")
      expect(card_status).to include("RuntimeProvider.connect(provider)")
      expect(card_status).to include("RuntimeProvider.discover(provider)")
      expect(card_status).to include("RuntimeProvider.statusView(data)")
    end

    it "does not reinterpret a legacy API card when its provider id collides with a runtime provider" do
      provider = function_source(settings, "_getProvider")
      resolve = function_source(settings, "_resolveModalProviderId")

      expect(provider).to include("RuntimeProvider.isRuntimeProvider(provider)")
      expect(provider).to include("model.runtime_id === provider.runtime_id")
      expect(resolve).to include("_getProvider(model)")
      expect(resolve).not_to include("if (model.provider_id) return model.provider_id")
    end

    it "connects and discovers models from both the modal and configured cards" do
      modal_status = function_source(settings, "_refreshModalRuntimeStatus")
      card_status = function_source(settings, "_refreshRuntimeCardStatus")
      expect(modal_status).to include("RuntimeProvider.connect(provider)")
      expect(modal_status).to include("RuntimeProvider.discover(provider)")
      expect(card_status).to include("RuntimeProvider.connect(provider)")
      expect(card_status).to include("RuntimeProvider.discover(provider)")
      dropdown = function_source(settings, "_updateModalModelDropdown")
      expect(dropdown).to include("runtime ? _modalRuntimeModels")
    end

    it "does not offer the API-card duplicate action for runtime cards" do
      render = function_source(settings, "_renderCard")
      duplicate = function_source(settings, "_openModalDuplicate")
      expect(render).to match(/!RuntimeProvider\.isRuntimeProvider\(provider\).*?data-action="duplicate"/m)
      expect(duplicate).to include("RuntimeProvider.isRuntimeProvider")
    end

    it "polls nonterminal card states and rejects stale card or render responses" do
      render_cards = function_source(settings, "_renderCards")
      card_status = function_source(settings, "_refreshRuntimeCardStatus")
      test_model = function_source(settings, "_testModel")
      expect(settings).to include("let _runtimeCardStatusGeneration")
      expect(settings).to include("let _runtimeCardStatusRequest")
      expect(render_cards).to include("++_runtimeCardStatusGeneration")
      expect(card_status).to include("RuntimeProvider.pollStatus")
      expect(card_status).to include("shouldContinue: isCurrent")
      expect(card_status).to include("generation !== _runtimeCardStatusGeneration")
      expect(card_status).to include("_runtimeCardStatusRequests.get(model.id) !== request")
      expect(test_model).to include("_runtimeCardStatusRequests.set(model.id, request)")
      expect(test_model).to include("generation !== _runtimeCardStatusGeneration")
      expect(test_model).to include("_runtimeCardStatusRequests.get(model.id) !== request")
    end

    it "keeps removed runtime cards identifiable but unavailable" do
      provider = function_source(settings, "_getProvider")
      selected = function_source(settings, "_selectedModalProvider")
      render = function_source(settings, "_renderCard")
      expect(provider).to include("model.runtime_id")
      expect(provider).to include("unavailable: true")
      expect(selected).to include("_getProvider")
      expect(render).to include("model.runtime_available !== false")
    end
  end

  describe "runtime model display" do
    it "falls back to display_model in Settings, model picker, and new-session chip" do
      expect(settings).to include("RuntimeProvider.displayModel(model, provider)")
      expect(model_picker).to include("RuntimeProvider.displayModel(m)")
      expect(new_session).to include("RuntimeProvider.displayModel(found)")
    end

    it "shows the per-session model and reasoning-effort hint in the model picker" do
      expect(model_picker).to include("m.runtime_id")
      expect(model_picker).to include('I18n.t("runtime.provider.dynamicHint")')
    end

    it "keeps available runtime cards selectable and disables unavailable or cross-kind choices" do
      expect(model_picker).to include("isSelectable")
      expect(model_picker).to include('aria-disabled')
      expect(sessions).to include("currentIsRuntime")
      expect(sessions).to include("isSelectable:")
      expect(sessions).to include("m.id === effectiveCurrentId")
      expect(new_session).to include("m.runtime_available !== false")
      expect(new_session).to include("isSelectable:")
    end

    it "ships localized session model-picker empty and error states" do
      %w[
        sib.model.empty sib.model.loadError sib.model.switchError
        sib.model.switchSubmodelError sib.model.unknownError
      ].each do |key|
        expect(i18n.scan(%("#{key}")).length).to be >= 2, "missing bilingual key #{key}"
      end
    end


    it "cancels onboarding and modal polling after their provider context changes" do
      expect(function_source(onboard, "_refreshSetupRuntimeStatus")).to include("shouldContinue: isCurrent")
      expect(function_source(onboard, "_authenticateSetupRuntime")).to include("shouldContinue: isCurrent")
      expect(function_source(settings, "_refreshModalRuntimeStatus")).to include("shouldContinue: isCurrent")
      expect(function_source(settings, "_authenticateModalRuntime")).to include("shouldContinue: isCurrent")
    end

    it "never writes benchmark state into a runtime row without a latency cell" do
      benchmark = function_source(model_picker, "_runBenchmark")
      expect(benchmark.scan(/if \(!cell\) return/).length).to be >= 2
    end

    it "renders runtime reasoning as read-only instead of opening the API switcher" do
      expect(sessions).to include("const previousSessionId = this._lastSession && this._lastSession.id")
      expect(sessions).to include("ReasoningEffortSwitcher.close()")
      expect(sessions).to include("const ReasoningEffortSwitcher = (() =>")
      expect(sessions).to include("const reasoningMutable = !s.runtime_id")
      expect(sessions).to include('sibReasoning.dataset.reasoningMutable = String(reasoningMutable)')
      expect(sessions).to include('sibReasoning.classList.toggle("sib-reasoning-disabled", !reasoningMutable)')
      expect(sessions).to include('if (el.dataset.reasoningMutable !== "true") return')
      expect(i18n.scan(%("sib.reasoning.runtimeManaged")).length).to be >= 2
      expect(i18n.scan(%("sib.reasoning.pending")).length).to be >= 2
      expect(sessions).to include('I18n.t("sib.reasoning.pending")')
    end

    it "omits fork controls for runtime sessions" do
      expect(sessions).to include("if (session.runtime_id) return")
      expect(sessions).to include("const forkItemHtml = session.runtime_id ? \"\"")
      expect(sessions).to include("${forkItemHtml}")
    end

    it "does not advertise OpenClacky skills or project initialization to runtime sessions" do
      runtime_check = function_source(new_session, "_selectedModelIsRuntime")
      context_bar = function_source(new_session, "_renderContextBar")
      submit = function_source(new_session, "_submit")
      send_button = function_source(new_session, "_updateSendButton")

      expect(runtime_check).to include("model.runtime_id")
      expect(context_bar).to include("const hostCommandsAvailable = _modelsLoaded && !runtimeModel")
      expect(context_bar).to include('const slashButton = $("ns-btn-slash")')
      expect(context_bar).to include("slashButton.hidden = !hostCommandsAvailable")
      expect(context_bar).to match(/agent && agent\.id === "coding" && hostCommandsAvailable/)
      expect(submit).to match(/initProject.*?&&\s*!_selectedModelIsRuntime\(\)/m)
      expect(send_button).to match(/initProject.*?&&\s*!_selectedModelIsRuntime\(\)/m)
      expect(new_session).to include("isEnabled: () => _modelsLoaded && !_selectedModelIsRuntime()")
      expect(new_session).to include("if (!_modelsLoaded || _selectedModelIsRuntime()) return []")
      expect(skills).to include("isEnabled")
      expect(skills).to include("if (!_isEnabled())")
      expect(sessions).to include('const slashButton = $("btn-slash")')
      expect(sessions).to include("slashButton.hidden = !!s.runtime_id")
      expect(app_css).to include('#btn-slash[hidden], #ns-btn-slash[hidden]')
    end

    it "blocks creation until the selected model kind is known and retries failed model loads" do
      populate = function_source(new_session, "_populateModels")
      submit = function_source(new_session, "_submit")
      panel_show = function_source(new_session, "onPanelShow")
      send_button = function_source(new_session, "_updateSendButton")
      load_models = function_source(new_session_store, "loadModels")

      expect(new_session).to include("let _modelsPromise = null")
      expect(populate).to include("if (_modelsPromise) return _modelsPromise")
      expect(populate).to include("if (!Array.isArray(models)) return false")
      expect(populate).to include("_modelsLoaded = true")
      expect(submit).to include("const modelsReady = await _populateModels()")
      expect(submit).to include("if (!modelsReady)")
      expect(panel_show).to include("await _populateModels()")
      expect(send_button).to include("!_modelsLoaded")
      expect(load_models.scan("return null").length).to be >= 2
      expect(i18n.scan(%("sessions.new.modelsUnavailable")).length).to be >= 2
    end

    it "discards stale asynchronous skill results after composer or session context changes" do
      render = function_source(skills, "_render")
      load_session = function_source(skills, "_loadForSession")

      expect(skills).to include("let _renderRequest")
      expect(skills).to include("let _snapshotRequest")
      expect(render).to include("const cfg = _cfg")
      expect(render).to include("request !== _renderRequest")
      expect(render).to include("_cfg !== cfg")
      expect(load_session).to include("_cfg = _chatCfg")
      expect(load_session).to include("_currentSession === sessionId")
    end
  end
end
