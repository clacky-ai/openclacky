---
name: new
description: Create a new project to start development quickly
agent: coding
disable-model-invocation: false
user-invocable: true
---

# Create New Project

## Usage
When user wants to create a new Rails project:
- "help me create a new Rails project"
- "I want to start a new Rails project"
- "/new"

## Process Steps

### 0. Ask Project Type and Requirement
Before doing anything, call `ask_user` with a structured prompt. Use the following as a guide:

zh:
```json
{
  "question": "请选择项目类型，并用一句话描述你想做什么：",
  "context": "开始新项目前需要知道项目类型和需求，请先完成填写。",
  "options": ["⚡ Demo — 无数据库，AI 自由发挥，快速原型", "🏗️ Production — 真实应用，可部署，完整 Rails 配置"]
}
```

en:
```json
{
  "question": "Choose a project type and describe what you want to build in one sentence:",
  "context": "Tell us what kind of project to create so we can get started.",
  "options": ["⚡ Demo — no database, AI builds freely, quick prototype", "🏗️ Production — real app, ready to deploy, full Rails setup"]
}
```

**Based on user's choice:**
- If **Demo**: do NOT follow the Rails setup steps below. Instead, freely build a simple HTML/CSS/JS (or React) prototype directly in the working directory based on their requirement. Use your creativity.
- If **Production**: continue with steps 1–3 below (full Rails flow).

### 1. Check Directory Before Starting
Before running the setup script, check if current directory is empty:
- Use glob tool to check if directory has files: `glob("*", base_path: ".")`
- If directory is NOT empty, ask user for confirmation: "Current directory is not empty. Continue anyway? (y/n)"
- If user declines, abort and suggest creating project in an empty directory

### 2. Run Setup Script
Execute the `create_rails_project.sh` script (see Supporting Files below) in current directory.
Use the exact absolute path shown in the Supporting Files section:
```bash
<absolute path to create_rails_project.sh from Supporting Files>
```

The script will automatically:

**Step 1: Clone Template**
- Clone rails-template-7x-starter to a temporary directory
- Move all files to current directory
- Delete template's .git directory
- Initialize new git repository with initial commit

**Step 2: Check Environment**
- Run rails_env_checker.sh to verify dependencies:
  - Ruby >= 3.3.0 (auto-installed via mise if missing or too old — supports CN mirrors)
  - Node.js >= 22.0.0 (will install automatically if missing on macOS/Ubuntu)
  - PostgreSQL (will install automatically if missing on macOS/Ubuntu)
- Script automatically installs missing dependencies without prompting

**Step 3: Install Project Dependencies**
- Run ./bin/setup to:
  - Install Ruby gems (bundle install)
  - Install npm packages (npm install)
  - Copy configuration files
  - Setup database (db:prepare)
  
**Step 4: Project Setup Complete**
- Script completes successfully
- Project is ready to run

### 3. Start Development Server
After the script completes, read the `.1024` config file in the project root
to find the `run_command`, then start it in the background via the terminal tool:

```
# First, read .1024 to get the run_command (usually `bin/dev` for Rails):
file_reader(path: ".1024")

# Then start the server in the background:
terminal(command: "<run_command from .1024>", background: true)
```

**Important**: If the terminal call returns a session_id (and no error), the
server has started successfully. You can inspect logs later by polling the
same session_id with an empty input.

Then inform the user and ask what to develop next:
```
✨ Rails project created successfully!

The development server is now running at: http://localhost:3000

You can open your browser and visit the URL to see the application.

What would you like to develop next?
```

## Error Handling
- Directory not empty → Ask user confirmation, abort if declined
- Git clone fails → Check network connection, verify repository URL
- Ruby < 3.3 or missing → **Automatically installs Ruby 3.3 via mise** (with CN mirror support); exits with instructions if mise install fails
- Node.js < 22 → Script installs automatically (macOS/Ubuntu)
- PostgreSQL missing → Script installs automatically (macOS/Ubuntu)
- bin/setup fails → Show error, suggest running `./bin/setup` manually
- Dev server fails to start → Poll the terminal session (empty input) to check logs, verify database status

## Example Interaction
User: "/new"

Response:
1. Checking if current directory is empty...
2. Running create_rails_project.sh in current directory
3. Cloning Rails template from GitHub...
4. Checking environment dependencies...
5. Installing project dependencies...
6. Project setup complete!
7. Starting development server via terminal (background)...
8. ✨ Server running! Visit http://localhost:3000
