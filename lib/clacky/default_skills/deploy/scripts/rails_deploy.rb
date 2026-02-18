# frozen_string_literal: true

require_relative '../tools/list_services'
require_relative '../tools/report_deploy_status'
require_relative '../tools/execute_deployment'
require_relative '../tools/set_deploy_variables'
require_relative '../tools/fetch_runtime_logs'
require_relative '../tools/check_health'

module Clacky
  module DeployTemplates
    # Rails deployment template - Fixed 8-step deployment process
    # No AI decision-making, pure automation
    class RailsDeploy
      # Execute the Rails deployment workflow
      #
      # @return [Hash] Deployment result
      def self.execute
        # CRITICAL: Check environment requirements
        unless environment_valid?
          return {
            success: false,
            error: "Railway deployment is only available in the Clacky cloud environment with Rails template projects.",
            details: environment_check_details
          }
        end

        puts "\n" + "="*60
        puts "🚂 Rails Deployment Template (8-Step Process)"
        puts "="*60 + "\n"

        # Step 1: List services
        step1_result = step1_list_services
        return step1_result unless step1_result[:success]
        
        services = step1_result[:services]
        main_service = step1_result[:main_service]
        db_service = step1_result[:db_service]

        # Step 2: Check first deployment
        step2_result = step2_check_first_deployment(main_service)
        return step2_result unless step2_result[:success]
        
        is_first = step2_result[:is_first_deployment]

        # Step 3: Set Rails environment variables
        step3_result = step3_set_rails_variables(main_service, db_service, is_first)
        return step3_result unless step3_result[:success]

        # Step 4: Execute deployment
        step4_result = step4_execute_deployment(main_service)
        return step4_result unless step4_result[:success]

        # Step 5: Run database migrations
        step5_result = step5_run_migrations(main_service)
        return step5_result unless step5_result[:success]

        # Step 6: Run database seeds (first deployment only)
        if is_first
          step6_result = step6_run_seeds(main_service)
          return step6_result unless step6_result[:success]
        else
          puts "\n[Step 6] Skipping database seeds (not first deployment)\n"
        end

        # Step 7: Health check
        step7_result = step7_health_check(main_service)
        return step7_result unless step7_result[:success]

        # Step 8: Report success
        step8_report_success(main_service)
      end

      # Check if environment is valid for deployment
      #
      # @return [Boolean] true if both required environment variables are "true"
      def self.environment_valid?
        ENV['IS_RAILS_TEMPLATE'] == 'true' && ENV['IS_CLACKY_CDE'] == 'true'
      end

      # Get environment check details for error reporting
      #
      # @return [Hash] Details about environment check
      def self.environment_check_details
        {
          is_rails_template: ENV['IS_RAILS_TEMPLATE'],
          is_clacky_cde: ENV['IS_CLACKY_CDE'],
          required: {
            is_rails_template: 'true',
            is_clacky_cde: 'true'
          }
        }
      end

      # Step 1: List Railway services
      def self.step1_list_services
        puts "\n[Step 1] Listing Railway services..."
        DeployTools::ReportDeployStatus.execute(
          status: 'analyzing',
          message: 'Listing Railway services'
        )

        result = DeployTools::ListServices.execute
        
        unless result[:success]
          return {
            success: false,
            error: "Failed to list services",
            details: result
          }
        end

        services = result[:services]
        
        # Find main web service
        main_service = services.find { |s| s['type'] == 'web' || s['type'] == 'service' }
        
        if main_service.nil?
          return {
            success: false,
            error: "No web service found",
            details: "Please create a web service in Railway first"
          }
        end

        # Find database service
        db_service = services.find { |s| s['type'] == 'postgres' || s['type'] == 'mysql' }

        puts "✅ Found #{services.length} service(s)"
        puts "   Main service: #{main_service['name']}"
        puts "   Database: #{db_service ? db_service['name'] : 'None'}"

        {
          success: true,
          services: services,
          main_service: main_service,
          db_service: db_service
        }
      end

      # Step 2: Check if this is first deployment
      def self.step2_check_first_deployment(main_service)
        puts "\n[Step 2] Checking deployment history..."

        deployments = main_service['deployments'] || []
        is_first = deployments.empty?

        if is_first
          puts "📦 This is the FIRST deployment"
        else
          puts "📦 This is a SUBSEQUENT deployment (#{deployments.length} previous deployment(s))"
        end

        {
          success: true,
          is_first_deployment: is_first,
          previous_deployments: deployments.length
        }
      end

      # Step 3: Set Rails environment variables
      def self.step3_set_rails_variables(main_service, db_service, is_first)
        puts "\n[Step 3] Setting Rails environment variables..."
        DeployTools::ReportDeployStatus.execute(
          status: 'analyzing',
          message: 'Configuring Rails environment variables'
        )

        service_name = main_service['name']
        
        # Build simple variables
        variables = {
          'RAILS_ENV' => 'production',
          'RAILS_SERVE_STATIC_FILES' => 'true',
          'RAILS_LOG_TO_STDOUT' => 'true'
        }

        # Get or prompt for SECRET_KEY_BASE
        secret_key_base = ENV['SECRET_KEY_BASE']
        if secret_key_base.nil? || secret_key_base.empty?
          puts "⚠️  SECRET_KEY_BASE not found. Please generate one:"
          puts "   Run: rails secret"
          print "Enter SECRET_KEY_BASE: "
          secret_key_base = $stdin.gets.chomp
        end
        variables['SECRET_KEY_BASE'] = secret_key_base

        # Build reference variables
        ref_variables = {}
        if db_service
          ref_variables['DATABASE_URL'] = "#{db_service['name']}.DATABASE_URL"
        end

        # Set variables
        result = DeployTools::SetDeployVariables.execute(
          service_name: service_name,
          variables: variables,
          ref_variables: ref_variables
        )

        unless result[:success]
          return {
            success: false,
            error: "Failed to set environment variables",
            details: result
          }
        end

        puts "✅ Set #{result[:set_variables].length} variable(s)"
        if result[:skipped_variables].any?
          puts "⚠️  Skipped #{result[:skipped_variables].length} protected variable(s)"
        end

        {
          success: true,
          set_count: result[:set_variables].length
        }
      end

      # Step 4: Execute deployment
      def self.step4_execute_deployment(main_service)
        puts "\n[Step 4] Executing deployment..."
        DeployTools::ReportDeployStatus.execute(
          status: 'deploying',
          message: 'Starting deployment to Railway'
        )

        service_name = main_service['name']
        result = DeployTools::ExecuteDeployment.execute(service_name: service_name)

        unless result[:success]
          # Fetch logs for debugging
          puts "\n❌ Deployment failed. Fetching logs..."
          log_result = DeployTools::FetchRuntimeLogs.execute(
            service_name: service_name,
            lines: 100
          )
          
          if log_result[:success]
            puts "\n📋 Last 100 lines of logs:"
            puts log_result[:logs]
          end

          return {
            success: false,
            error: "Deployment failed",
            details: result
          }
        end

        puts "✅ Deployment completed in #{result[:elapsed].round(1)}s"

        {
          success: true,
          elapsed: result[:elapsed]
        }
      end

      # Step 5: Run database migrations
      def self.step5_run_migrations(main_service)
        puts "\n[Step 5] Running database migrations..."

        service_name = main_service['name']
        command = "clackycli run -s '#{service_name}' rake db:migrate"
        
        puts "Running: rake db:migrate"
        output = `#{command} 2>&1`
        exit_code = $?.exitstatus

        if exit_code != 0
          return {
            success: false,
            error: "Database migration failed",
            details: output
          }
        end

        puts "✅ Database migrations completed"
        puts output if output && !output.empty?

        {
          success: true
        }
      end

      # Step 6: Run database seeds
      def self.step6_run_seeds(main_service)
        puts "\n[Step 6] Running database seeds..."

        service_name = main_service['name']
        command = "clackycli run -s '#{service_name}' rake db:seed"
        
        puts "Running: rake db:seed"
        output = `#{command} 2>&1`
        exit_code = $?.exitstatus

        if exit_code != 0
          puts "⚠️  Warning: Database seeding failed (this may be expected)"
          puts output if output && !output.empty?
        else
          puts "✅ Database seeding completed"
          puts output if output && !output.empty?
        end

        # Don't fail deployment if seeding fails
        {
          success: true
        }
      end

      # Step 7: Health check
      def self.step7_health_check(main_service)
        puts "\n[Step 7] Performing health check..."
        DeployTools::ReportDeployStatus.execute(
          status: 'checking',
          message: 'Verifying application health'
        )

        public_url = main_service['public_url']
        
        if public_url.nil? || public_url.empty?
          puts "⚠️  Warning: No public URL found. Skipping health check."
          return { success: true }
        end

        # Wait a bit for service to be fully ready
        puts "⏳ Waiting 10 seconds for service to be ready..."
        sleep 10

        result = DeployTools::CheckHealth.execute(
          url: public_url,
          path: '/',
          timeout: 30
        )

        unless result[:success]
          puts "⚠️  Warning: Health check failed (service may still be starting)"
          puts "   Error: #{result[:error]}"
          puts "   You can manually check: #{public_url}"
          # Don't fail deployment on health check failure
        else
          puts "✅ Health check passed (#{result[:status_code]} - #{result[:elapsed]}s)"
        end

        {
          success: true,
          health_check_result: result
        }
      end

      # Step 8: Report success
      def self.step8_report_success(main_service)
        puts "\n[Step 8] Deployment completed successfully! 🎉"
        
        public_url = main_service['public_url']
        
        DeployTools::ReportDeployStatus.execute(
          status: 'success',
          message: "Rails app deployed successfully"
        )

        puts "\n" + "="*60
        puts "✅ DEPLOYMENT SUCCESSFUL"
        puts "="*60
        puts "Service: #{main_service['name']}"
        puts "URL: #{public_url || 'Not available yet'}" 
        puts "="*60 + "\n"

        {
          success: true,
          service: main_service['name'],
          url: public_url
        }
      end
    end
  end
end

# Run deployment if executed directly
if __FILE__ == $0
  result = Clacky::DeployTemplates::RailsDeploy.execute
  exit(result[:success] ? 0 : 1)
end
