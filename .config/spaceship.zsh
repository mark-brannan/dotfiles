# Display time
SPACESHIP_TIME_SHOW=true

# Display username always
# SPACESHIP_USER_SHOW=always

# Do not truncate path in repos
SPACESHIP_DIR_TRUNC_REPO=false

# Add custom Ember section
# See: https://github.com/spaceship-prompt/spaceship-ember
#spaceship add ember

# Add a custom vi-mode section to the prompt
# See: https://github.com/spaceship-prompt/spaceship-vi-mode
spaceship add --before char vi_mode

SPACESHIP_SUDO_SHOW=true

# Spaceship settings (fixed syntax)
SPACESHIP_PROMPT_ASYNC=true
SPACESHIP_PROMPT_ADD_NEWLINE=false
#SPACESHIP_CHAR_SYMBOL="⚡"

# Minimal spaceship sections for performance
#SPACESHIP_PROMPT_ORDER=(
  #time
  #user
  #dir
  #git
  #docker
  #async
  #line_sep
  #sudo
  #char
#)
