if [[ $- != *i* ]] ; then
    # Shell is non-interactive.  Be done now!
    return
fi

shopt -s checkwinsize
shopt -s histappend

# Display LANG only in interactive login shells
[[ -n "$PS1" ]] && echo "Current locale: $LANG"

export HISTTIMEFORMAT="%h/%d - %H:%M:%S "
export HISTSIZE=100000
export PS1="\[\u@$(hostname -f): \w\]\$ "
case ${TERM} in
  xterm*|rxvt*|Eterm|aterm|kterm|gnome*)
    PROMPT_COMMAND=${PROMPT_COMMAND:+$PROMPT_COMMAND; }'printf "\033]0;%s@%s:%s\007" "${USER}" "${HOSTNAME%%.*}" "${PWD/#$HOME/~}"'
    ;;
  screen)
    PROMPT_COMMAND=${PROMPT_COMMAND:+$PROMPT_COMMAND; }'printf "\033_%s@%s:%s\033\\" "${USER}" "${HOSTNAME%%.*}" "${PWD/#$HOME/~}"'
    ;;
esac

use_color=true
safe_term=${TERM//[^[:alnum:]]/?}
match_lhs=""

[[ -f ~/.dir_colors   ]] && match_lhs="${match_lhs}$(<~/.dir_colors)"
[[ -f /etc/DIR_COLORS ]] && match_lhs="${match_lhs}$(</etc/DIR_COLORS)"
[[ -z ${match_lhs}    ]] \
    && type -P dircolors >/dev/null \
    && match_lhs=$(dircolors --print-database)
[[ $'\n'${match_lhs} == *$'\n'"TERM "${safe_term}* ]] && use_color=true

if ${use_color} ; then
    # Enable colors for ls, etc.  Prefer ~/.dir_colors #64489
    if type -P dircolors >/dev/null ; then
        if [[ -f ~/.dir_colors ]] ; then
            eval $(dircolors -b ~/.dir_colors)
        elif [[ -f /etc/DIR_COLORS ]] ; then
            eval $(dircolors -b /etc/DIR_COLORS)
        fi
    fi

    if [[ ${EUID} == 0 ]] ; then
        ## default prompt
        PS1='\[\033[01;31m\]\u\[\033[01;32m\]@$(hostname -f) \w \$\[\033[00m\] '
    else
        PS1='\[\033[01;32m\]\u\[\033[01;32m\]@$(hostname -f) \w \$\[\033[00m\] '
    fi

## With Git Branch
#        PS1="\[\033[01;31m\]\u\[\033[01;32m\]@$(hostname -f) \w \$\[\033[00m\] \[\033[38;5;11m\](\$(git branch 2>/dev/null | grep '^*' | colrm 1 2)) \[\033[01;32m\]\$\[\033[00m\] "
#    else
#        PS1="\[\033[01;32m\]\u\[\033[01;32m\]@$(hostname -f) \w \$\[\033[00m\] \[\033[38;5;11m\](\$(git branch 2>/dev/null | grep '^*' | colrm 1 2)) \[\033[01;32m\]\$\[\033[00m\] "
#    fi


#    alias ls='ls --color=auto'
    alias dir='dir --color=auto'
    alias grep='grep --colour=auto'
#    alias ll='ls --color=auto -la'
#    alias l='ls --color=auto -lA'
else
    if [[ ${EUID} == 0 ]] ; then
        # show root@ when we do not have colors
        PS1='\[\u@$(hostname -f): \w\]\$ '
    else
        PS1='\[\u@$(hostname -f): \w\]\$ '
    fi
fi

PS2='> '
PS3='> '
PS4='+ '

unset use_color safe_term match_lhs

# Ubuntu/Debian
[ -r /etc/bash_completion ] && . /etc/bash_completion

# Определение переменной с именем утилиты: bat или batcat
if [[ -e $(which batcat) ]]; then
    export bat="batcat"
    alias bat="batcat"
elif [[ -e $(which bat) ]]; then
    export bat="bat"
fi

# Конфигурация утилиты bat
if [[ -n $bat ]]; then
    export COLORTERM="truecolor"
    export BAT_THEME="Nord"  # Цветовая тема
    export MANPAGER="sh -c 'col -bx | $bat --language=man --style=plain'"  # Команда для просмотра man-страниц
    export MANROFFOPT="-c"  # Отключение перенос строк в man
    alias cat="$bat --style=plain --paging=never"
    alias less="$bat --paging=always"
    if [[ $SHELL == *zsh ]]; then # глобальный алиас --help если оболочка zsh
        alias -g -- --help='--help 2>&1 | $bat --language=help --style=plain'
    fi
    # Функции help имитирует ключ --help только с bat, пример: help ls
    help() { "$@" --help 2>&1 | $bat --language=help --style=plain; }
    # Функция tailf - аналог tail -f только с bat
    tailf() { tail -f "$@" | $bat --paging=never --language=log; }
    # Функция для просмотра изменений git diff с помощью bat
    batdiff() { git diff --name-only --relative --diff-filter=d | xargs $bat --diff; }
fi

# Настройка exa как замены ls
if [[ -e $(which exa) ]]; then
    if [[ -n "$DISPLAY" || $(tty) == /dev/pts* ]]; then # отображать иконки если псевдотерминал
        alias ls="exa --group --header --icons"
    else
        alias ls="exa --group --header"
    fi
    alias ll="ls --long"
    alias l="ls --long --all --header"
    alias lm="ls --long --all --sort=modified"
    alias lmm="ls -lbHigUmuSa --sort=modified --time-style=long-iso"
    alias lt="ls --tree"
    alias lr="ls --recurse"
    alias lg="ls --long --git --sort=modified"
fi

# Load shipped aliases (configs/.bash_aliases)
if [ -f ~/.bash_aliases ]; then
  . ~/.bash_aliases
fi

# Load aliases customizations
if [[ -f ~/.bashrc_aliases ]]; then
    source ~/.bashrc_aliases
fi
