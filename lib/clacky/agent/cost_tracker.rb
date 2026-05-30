# frozen_string_literal: true

require_relative "../billing/billing_store"
require_relative "../billing/billing_record"

module Clacky
  class Agent
    # Cost tracking and token usage statistics
    # Manages cost calculation, token estimation, and usage display
    module CostTracker
      # Lazy-loaded billing store instance
      def billing_store
        @billing_store ||= Billing::BillingStore.new
      end

      # Track cost from API usage
      # Updates total cost and displays iteration statistics
      # @param usage [Hash] Usage data from API response
      # @param raw_api_usage [Hash, nil] Raw API usage data for debugging
      # @param model [String, nil] Model name to use for billing (defaults to current_model)
      def track_cost(usage, raw_api_usage: nil, model: nil)
        # Priority 1: Use API-provided cost if available (OpenRouter, LiteLLM, etc.)
        iteration_cost = nil
        if usage[:api_cost]
          @total_cost += usage[:api_cost]
          @cost_source = :api
          @task_cost_source = :api
          iteration_cost = usage[:api_cost]
          @ui&.log("Using API-provided cost: $#{usage[:api_cost]}", level: :debug) if @config.verbose
        else
          # Priority 2: Calculate from tokens using ModelPricing
          # Use provided model name (from API call time) to ensure accurate billing
          # even if the user switches models during the API call
          billing_model = model || current_model
          result = ModelPricing.calculate_cost(model: billing_model, usage: usage)
          cost = result[:cost]
          pricing_source = result[:source]

          # Only accumulate cost when the model has known pricing.
          # Unknown models return nil — display N/A, don't add to total.
          if cost
            @total_cost += cost
            iteration_cost = cost
            @cost_source = pricing_source
            @task_cost_source = pricing_source
          end

          if @config.verbose
            if cost
              source_label = pricing_source == :price ? "model pricing" : "default pricing"
              @ui&.log("Calculated cost for #{@config.model_name} using #{source_label}: $#{cost.round(6)}", level: :debug)
            else
              @ui&.log("No pricing data available for #{@config.model_name} — cost is unknown", level: :debug)
            end
            @ui&.log("Usage breakdown: prompt=#{usage[:prompt_tokens]}, completion=#{usage[:completion_tokens]}, cache_write=#{usage[:cache_creation_input_tokens] || 0}, cache_read=#{usage[:cache_read_input_tokens] || 0}", level: :debug)
          end
        end

        # Collect token usage data for this iteration (returned to caller for deferred display)
        token_data = collect_iteration_tokens(usage, iteration_cost)

        # Update session bar cost in real-time (don't wait for agent.run to finish).
        # Subagents must NOT push their own (small, restarting-from-zero) cost into the
        # shared UI — that would clobber the parent's accumulated total and cause the
        # session bar to "jump back to ~$0" while a subagent is running, then snap back
        # to the real total once the parent merges the subagent's cost. The parent agent
        # is responsible for surfacing the merged cost after fork_subagent returns
        # (see SkillManager#execute_skill_with_subagent and MemoryUpdater).
        @ui&.update_sessionbar(cost: @total_cost, cost_source: @cost_source) unless @is_subagent

        # Track cache usage statistics (global)
        @cache_stats[:total_requests] += 1

        if usage[:cache_creation_input_tokens]
          @cache_stats[:cache_creation_input_tokens] += usage[:cache_creation_input_tokens]
        end

        if usage[:cache_read_input_tokens]
          @cache_stats[:cache_read_input_tokens] += usage[:cache_read_input_tokens]
          @cache_stats[:cache_hit_requests] += 1
        end

        # Store raw API usage samples (keep last 3 for debugging)
        if raw_api_usage
          @cache_stats[:raw_api_usage_samples] ||= []
          @cache_stats[:raw_api_usage_samples] << raw_api_usage
          @cache_stats[:raw_api_usage_samples] = @cache_stats[:raw_api_usage_samples].last(3)
        end

        # Track cache usage for current task
        if @task_cache_stats
          @task_cache_stats[:total_requests] += 1
          @task_cache_stats[:prompt_tokens] += usage[:prompt_tokens].to_i
          @task_cache_stats[:completion_tokens] += usage[:completion_tokens].to_i

          if usage[:cache_creation_input_tokens]
            @task_cache_stats[:cache_creation_input_tokens] += usage[:cache_creation_input_tokens]
          end

          if usage[:cache_read_input_tokens]
            @task_cache_stats[:cache_read_input_tokens] += usage[:cache_read_input_tokens]
            @task_cache_stats[:cache_hit_requests] += 1
          end
        end

        # Persist billing record (skip for subagents to avoid double-counting)
        unless @is_subagent
          persist_billing_record(usage, iteration_cost, model: model)
        end

        # Return token_data so the caller can display it at the right moment
        token_data
      end

      # Persist a billing record to the billing store
      # @param usage [Hash] Usage data from API
      # @param cost [Float, nil] Calculated cost for this iteration
      # @param model [String, nil] Model name to use for billing (defaults to current_model)
      def persist_billing_record(usage, cost, model: nil)
        # Always save billing records for usage tracking, even if cost is unknown (nil).
        # This ensures all API calls are recorded for statistics purposes.
        billing_model = model || current_model
        effective_cost = cost || 0.0  # Use 0 if pricing is unknown

        record = Billing::BillingRecord.new(
          session_id: @session_id,
          timestamp: Time.now,
          model: billing_model,
          prompt_tokens: usage[:prompt_tokens] || 0,
          completion_tokens: usage[:completion_tokens] || 0,
          cache_read_tokens: usage[:cache_read_input_tokens] || 0,
          cache_write_tokens: usage[:cache_creation_input_tokens] || 0,
          cost_usd: effective_cost,
          cost_source: cost.nil? ? :unknown : @cost_source
        )

        billing_store.append(record)
      rescue => e
        # Billing persistence is non-critical; log and continue
        Clacky::Logger.warn("billing.persist_error", error: e.message, model: billing_model)
      end

      # Estimate token count for a message content
      # Simple approximation: characters / 4 (English text)



      # Collect token usage data for current iteration and return it.
      # Does NOT call @ui directly — the caller is responsible for displaying
      # at the right moment (e.g. after show_assistant_message).
      # @param usage [Hash] Usage data from API
      # @param cost [Float] Cost for this iteration
      # @return [Hash] token_data ready for show_token_usage
      def collect_iteration_tokens(usage, cost)
        prompt_tokens = usage[:prompt_tokens] || 0
        completion_tokens = usage[:completion_tokens] || 0
        total_tokens = usage[:total_tokens] || (prompt_tokens + completion_tokens)
        cache_write = usage[:cache_creation_input_tokens] || 0
        cache_read = usage[:cache_read_input_tokens] || 0

        # Calculate token delta from previous iteration.
        #
        # Two conventions exist for total_tokens across providers:
        #   - OpenAI (default):    cumulative per-request input+output (grows
        #                          with history every turn). Delta = total - prev.
        #   - Anthropic direct:    already the per-turn new compute
        #                          (raw_input + cache_creation + output).
        #                          The MessageFormat sets :total_is_per_turn so
        #                          we use total_tokens directly as the delta.
        #
        # Without this branch, Anthropic's per-turn total would be treated as
        # cumulative and produce negative / nonsensical deltas whenever cached
        # prefixes make the per-turn new-compute smaller than the previous turn.
        delta_tokens =
          if usage[:total_is_per_turn]
            total_tokens
          else
            total_tokens - @previous_total_tokens
          end

        # Guard: do NOT overwrite @previous_total_tokens with 0 when the upstream
        # returns missing/zero usage (observed when history overflows the model
        # context: response comes back as content="" + finish_reason="stop" +
        # zero usage). Resetting to 0 would disable the compression trigger on
        # subsequent turns and poison the session permanently.
        @previous_total_tokens = total_tokens if total_tokens > 0

        {
          delta_tokens: delta_tokens,
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          total_tokens: total_tokens,
          cache_write: cache_write,
          cache_read: cache_read,
          cost: cost,
          cost_source: @cost_source
        }
      end
    end
  end
end
