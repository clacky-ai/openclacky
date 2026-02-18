# Deploy Feature Design Document

## 1. Overview

This document describes the design of the deployment feature for OpenClacky that deploys user projects to Railway PaaS.

### 1.1 Dual-Mode Approach

The deployment feature uses **two distinct modes** to balance precision and flexibility:

1. **Rails Mode** (Priority)
   - Fixed 8-step script execution
   - No AI decision-making, pure automation
   - Fast, predictable, and precise
   - For standard Rails projects only

2. **Generic Mode**
   - AI-guided subagent (DeployRole)
   - Intelligent analysis and decision-making
   - Flexible handling of edge cases
   - For non-Rails or non-standard projects

**Design Philosophy**: Rails projects get precise, automated deployment; everything else gets intelligent, adaptive deployment.

### 1.2 Goals

- Port deployment functionality from clacky-ai-agent to OpenClacky (Ruby)
- Prioritize Rails project deployment (OpenClacky's primary focus)
- Maintain generality for other project types (Node.js, Python, etc.)
- Provide fast, reliable deployment experience

### 1.3 Reference Implementation

- Source project: `~/workspace/clacky-ai-agent`
- Key files:
  - `heracles/agent_roles/deploy_role/` - DeployRole implementation
  - `heracles/agent_workspace/tools/deploy.py` - Deployment tools
  - `heracles/agent_workspace/deployment/deployment.py` - Deployment logic

## 2. Architecture Design

### 2.1 Overall Architecture

```
User: "Deploy my project"
        ↓
invoke_skill('deploy', task: 'Deploy project')
        ↓
Deploy Skill (SKILL.md) - Project Type Detection
        ↓
        ├─── Rails Project Detected
        │    (Gemfile + config/database.yml exist)
        │           ↓
        │    Execute rails_deploy.rb Template
        │    ├─ Step 1: List services
        │    ├─ Step 2: Check first deployment
        │    ├─ Step 3: Set Rails env vars
        │    ├─ Step 4: Execute deployment
        │    ├─ Step 5: Run db:migrate
        │    ├─ Step 6: Run db:seed (if first)
        │    ├─ Step 7: Health check
        │    └─ Step 8: Report success
        │           ↓
        │    Return result (synchronous)
        │
        └─── Non-Rails Project
             (Node.js / Python / Generic)
                    ↓
             Fork DeployRole Subagent
             ├─ Phase 1: Analyzing (AI analyzes)
             ├─ Phase 2: Deploying (AI deploys)
             └─ Phase 3: Checking (AI verifies)
                    ↓
             Return result (synchronous)
```

### 2.2 Component Structure

```
default_skills/deploy/
├── SKILL.md                       # Deploy skill entry point
│                                  # - Detects project type
│                                  # - Routes to Rails template or Generic subagent
│
├── templates/
│   └── rails_deploy.rb            # Fixed 8-step Rails deployment script
│                                  # - No AI decision-making
│                                  # - Precise, automated execution
│
├── subagent/
│   └── DEPLOY_ROLE.md             # Generic deployment subagent system prompt
│                                  # - 3-phase AI-guided workflow
│                                  # - Intelligent analysis and adaptation
│
└── tools/                         # Deployment tools (used by both modes)
    ├── list_services.rb           # List Railway services
    ├── report_deploy_status.rb    # Report deployment status
    ├── execute_deployment.rb      # Execute deployment
    ├── set_deploy_variables.rb    # Set environment variables
    ├── fetch_runtime_logs.rb      # Fetch runtime logs
    └── check_health.rb            # Health check

docs/
└── deploy_subagent_design.md      # This document
```

## 3. Project Type Detection

### 3.1 Detection Logic

The Deploy skill (SKILL.md) performs project type detection:

```ruby
# Pseudocode
def detect_project_type
  if File.exist?('Gemfile') && File.exist?('config/database.yml')
    :rails
  elsif File.exist?('package.json')
    :nodejs
  else
    :generic
  end
end
```

### 3.2 Routing Decision

- **Rails detected** → Execute `templates/rails_deploy.rb`
- **Non-Rails detected** → Fork DeployRole subagent with `subagent/DEPLOY_ROLE.md`

## 4. Rails Mode Design

### 4.1 Rails Template Script

**File**: `default_skills/deploy/templates/rails_deploy.rb`

**Purpose**: Fixed, non-AI script that executes precise deployment steps.

**Characteristics**:
- No AI decision-making
- No deviation from script
- Fast execution
- Predictable results

### 4.2 Rails Deployment Steps

```ruby
# Step 1: List Services
services = call_tool('list_services')
main_service = services.find { |s| s['type'] == 'web' }
db_service = services.find { |s| s['type'] == 'postgres' || s['type'] == 'mysql' }

# Step 2: Check First Deployment
is_first_deployment = main_service['deployments'].empty?

# Step 3: Set Rails Environment Variables
variables = {
  'RAILS_ENV' => 'production',
  'SECRET_KEY_BASE' => get_or_prompt('SECRET_KEY_BASE'),
  'RAILS_SERVE_STATIC_FILES' => 'true',
  'RAILS_LOG_TO_STDOUT' => 'true'
}

# Add DATABASE_URL reference
ref_variables = {
  'DATABASE_URL' => "#{db_service['name']}.DATABASE_URL"
}

call_tool('set_deploy_variables', 
  service: main_service['name'], 
  variables: variables,
  ref_variables: ref_variables
)

# Step 4: Execute Deployment
call_tool('execute_deployment', service: main_service['name'])

# Step 5: Run Database Migrations
run_railway_command(service: main_service['name'], 
                    command: 'rake db:migrate')

# Step 6: Run Database Seeds (first deployment only)
if is_first_deployment
  run_railway_command(service: main_service['name'], 
                      command: 'rake db:seed')
end

# Step 7: Health Check
public_url = main_service['public_url']
call_tool('check_health', url: public_url, path: '/')

# Step 8: Report Success
call_tool('report_deploy_status', 
  status: 'success', 
  message: "Rails app deployed successfully to #{public_url}"
)
```

### 4.3 Rails-Specific Features

1. **Automatic database.yml parsing**
2. **Rails environment variables** (RAILS_ENV, SECRET_KEY_BASE, etc.)
3. **Database migrations** (db:migrate)
4. **Database seeding** (db:seed on first deploy)
5. **Asset precompilation** (if needed)

## 5. Generic Mode Design

### 5.1 DeployRole Subagent

**File**: `default_skills/deploy/subagent/DEPLOY_ROLE.md`

**Purpose**: AI-guided deployment for non-standard or non-Rails projects.

**Characteristics**:
- Full AI decision-making
- Adaptive to project structure
- Handles edge cases
- 3-phase workflow

### 5.2 System Prompt Structure

```markdown
You are DeployRole, a deployment specialist for Railway PaaS.

Your task is to deploy the user's project using a 3-phase workflow.

## Phase 1: Analyzing

1. Use list_services to see existing Railway services
2. Detect project type (Node.js, Python, etc.) by reading project files
3. Analyze environment variable requirements (.env, .env.example)
4. Use collect_user_input to gather missing credentials
5. Report status: report_deploy_status(status='analyzing', message='...')

## Phase 2: Deploying

1. Use set_deploy_variables to configure environment
2. Use execute_deployment to deploy the service
3. Monitor deployment progress
4. If deployment fails, use fetch_runtime_logs to diagnose
5. Report status: report_deploy_status(status='deploying', message='...')

## Phase 3: Checking

1. Wait for public URL to be available
2. Use check_health to verify application is responding
3. Verify critical functionality (if applicable)
4. Report final status: report_deploy_status(status='success'|'failed', message='...')

## Available Tools

- list_services
- report_deploy_status
- execute_deployment
- set_deploy_variables
- fetch_runtime_logs
- check_health
- read_file
- search_codebase
- safe_shell
- collect_user_input
```

### 5.3 Generic Mode Workflow

Unlike Rails mode, the subagent:
- **Analyzes** the project structure intelligently
- **Adapts** to different frameworks and configurations
- **Decides** what commands to run based on context
- **Handles** errors with fallback strategies

## 6. Deployment Tools Design

All tools are **shared** between Rails and Generic modes.

### 6.1 list_services

**Purpose**: List all Railway services with environment variables.

**Parameters**: None

**Returns**: Array of service objects with masked sensitive data

**Implementation**: Wraps `clackycli service list --json`

### 6.2 report_deploy_status

**Purpose**: Report deployment status to user.

**Parameters**:
- `status`: analyzing | deploying | checking | success | failed
- `message`: Status message

**Implementation**: Outputs formatted status message

### 6.3 execute_deployment

**Purpose**: Execute deployment and monitor until completion.

**Parameters**:
- `service_name`: Service to deploy

**Implementation**: 
- Runs `clackycli up -s SERVICE_NAME -d`
- Monitors deployment status
- Returns when complete or failed

### 6.4 set_deploy_variables

**Purpose**: Set environment variables for a service.

**Parameters**:
- `service_name`: Target service
- `variables`: Hash of KEY => VALUE (simple variables)
- `ref_variables`: Hash of KEY => SERVICE.VAR (reference variables)

**Implementation**: Runs `clackycli variables -s SERVICE --set KEY=VALUE`

**Security**: Masks sensitive variable names (PASSWORD, SECRET, API_KEY, TOKEN)

### 6.5 fetch_runtime_logs

**Purpose**: Fetch runtime logs from deployed service.

**Parameters**:
- `service_name`: Service to fetch logs from
- `lines`: Number of lines (default: 100)

**Implementation**: Runs `clackycli logs --lines N`

### 6.6 check_health

**Purpose**: Perform HTTP health check on deployed application.

**Parameters**:
- `url`: Optional, defaults to RAILWAY_PUBLIC_DOMAIN
- `path`: Health check path, default "/"
- `timeout`: Request timeout in seconds, default 30

**Implementation**: HTTP GET request with timeout

## 7. Implementation Plan

### Phase 1: Core Tools (Week 1)

- [ ] Create skill directory structure: `default_skills/deploy/`
- [ ] Implement `list_services` tool
- [ ] Implement `report_deploy_status` tool
- [ ] Implement `set_deploy_variables` tool
- [ ] Write RSpec tests for core tools

### Phase 2: Deployment Tools (Week 2)

- [ ] Implement `execute_deployment` tool
- [ ] Implement `fetch_runtime_logs` tool
- [ ] Implement `check_health` tool
- [ ] Write integration tests
- [ ] Test all tools with Railway CLI

### Phase 3: Rails Mode (Week 3)

- [ ] Create `templates/rails_deploy.rb` script
- [ ] Implement 8-step Rails deployment workflow
- [ ] Add Rails project detection logic
- [ ] Test with real Rails projects
- [ ] Handle edge cases (missing SECRET_KEY_BASE, etc.)

### Phase 4: Generic Mode (Week 4)

- [ ] Create `subagent/DEPLOY_ROLE.md` system prompt
- [ ] Write comprehensive 3-phase workflow instructions
- [ ] Configure tool access for subagent
- [ ] Test with Node.js projects
- [ ] Test with Python projects

### Phase 5: Integration & Entry Point (Week 5)

- [ ] Create `SKILL.md` entry point
- [ ] Implement project type detection
- [ ] Implement routing logic (Rails vs Generic)
- [ ] End-to-end testing for both modes
- [ ] Error handling improvements

### Phase 6: Documentation & Polish (Week 6)

- [ ] User guide with examples
- [ ] API documentation
- [ ] Troubleshooting guide
- [ ] Performance optimization
- [ ] Security audit

## 8. Technical Decisions

### 8.1 CLI Tool Dependency

We depend on `clackycli` command-line tool for Railway operations.

**Commands used**:
- `clackycli service list --json` - List services
- `clackycli up -s SERVICE_NAME -d` - Deploy service
- `clackycli variables -s SERVICE_NAME --set KEY=VALUE` - Set variables
- `clackycli run -s SERVICE_NAME COMMAND` - Run commands
- `clackycli logs --lines N` - Fetch logs

### 8.2 Synchronous Execution

Both modes execute **synchronously** (user waits for completion).
No background/async execution.

**Rationale**:
- Simpler implementation
- Better error handling
- Clear user feedback
- Easier debugging

### 8.3 Rails Priority

Rails mode is implemented first and optimized for performance.
Generic mode is secondary but fully functional.

### 8.4 Tool Reusability

All tools are generic and reusable between modes.
No mode-specific tool implementations.

### 8.5 Error Handling

**Rails Mode**: Fail-fast with clear error messages
**Generic Mode**: AI attempts recovery, then fails with diagnosis

## 9. Security Considerations

1. **Mask sensitive environment variables**
   - PASSWORD, SECRET, API_KEY, TOKEN, etc.
   - Show only KEY=****** in logs

2. **Never modify CLACKY_* variables**
   - System variables are protected
   - Deployment tools skip them

3. **Use collect_user_input for secrets**
   - Prompt with password type
   - Never log secret values

4. **Sanitize command inputs**
   - Validate service names
   - Escape shell arguments

5. **Validate Railway CLI output**
   - Parse JSON safely
   - Handle missing fields gracefully

## 10. Success Criteria

### Rails Mode
1. ✓ Successfully deploy standard Rails projects
2. ✓ Handle first-time and subsequent deployments
3. ✓ Automatic database migration execution
4. ✓ Fast execution (< 5 minutes for typical project)
5. ✓ Clear progress reporting

### Generic Mode
1. ✓ Successfully deploy Node.js projects
2. ✓ Successfully deploy Python projects
3. ✓ Intelligent error diagnosis
4. ✓ Adaptive to different project structures
5. ✓ Clear AI reasoning in logs

### Overall
1. ✓ All RSpec tests passing
2. ✓ Complete documentation
3. ✓ No security vulnerabilities
4. ✓ Graceful error handling
5. ✓ User-friendly output

## 11. Comparison: Rails vs Generic Mode

| Aspect | Rails Mode | Generic Mode |
|--------|-----------|--------------|
| **Execution** | Fixed script | AI subagent |
| **AI Involvement** | None (pure automation) | Full (analysis + decisions) |
| **Speed** | Fast (< 5 min) | Slower (varies) |
| **Predictability** | 100% predictable | Adaptive |
| **Error Handling** | Fail-fast | Attempt recovery |
| **Flexibility** | None | High |
| **Use Case** | Standard Rails apps | Non-Rails or edge cases |
| **Database Setup** | Automatic (migrate + seed) | AI-decided |
| **Env Variables** | Fixed list | AI-analyzed |

## 12. Future Enhancements

1. **Additional Templates**
   - Node.js/Express template
   - Next.js template
   - Django template

2. **Multi-Platform Support**
   - Heroku integration
   - Render integration
   - Fly.io integration

3. **Advanced Features**
   - Rollback capabilities
   - Blue-green deployment
   - Deployment analytics
   - Pre/post deployment hooks

4. **AI Enhancements**
   - Cost estimation before deploy
   - Performance recommendations
   - Security scanning

5. **User Experience**
   - Interactive deployment wizard
   - Deployment history tracking
   - One-click rollback

## 13. Testing Strategy

### Unit Tests
- Each tool in isolation
- Mock Railway CLI responses
- Test error conditions

### Integration Tests
- Rails mode end-to-end
- Generic mode end-to-end
- Tool interaction flows

### Manual Tests
- Real Railway project deployment
- Different project types
- Error scenarios
- Security validations

### Test Coverage Target
- Tools: 90%+
- Rails template: 85%+
- Overall: 80%+
