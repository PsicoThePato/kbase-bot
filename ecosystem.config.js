module.exports = {
  apps: [{
    name: "kbase-bot",
    cwd: process.env.BOT_CWD || "./",
    script: "mix",
    args: "run --no-halt",
    interpreter: "none",
    env_file: ".env",
    autorestart: true,
    max_restarts: 10,
    restart_delay: 5000,
    log_date_format: "YYYY-MM-DD HH:mm:ss",
  }]
}
