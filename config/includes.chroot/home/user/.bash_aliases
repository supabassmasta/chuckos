alias b='cd $OLDPWD'
alias cdc='cd ~/chuck/dev/'
alias u='cd ..'
alias vi='gvim'
alias ctop='chuck song_top.ck'
#alias ctopj='chuckj song_top.ck --bufsize4096 --srate:44100'
alias ctap='chuck song_top.ck --bufsize64'
alias ctapj='chuckj song_top.ck --bufsize64 --srate:44100'
alias ctapp='chuckp song_top.ck --bufsize64'
#alias ctopp='chuckp song_top.ck'
alias vib='gvim ~/.bash_aliases ~/.bashrc'
alias srb='source ~/.bashrc'
alias f='find -name'
alias g='grep -r'
alias h='history'
alias chuckcfg='sudo chmod +r /dev/input/event4'
#alias ckcfg='echo "sudo chmod +r /dev/input/event"'
alias lsdev='ll /dev/input/by-path/;ll /dev/input'
alias randpwd='date +%s | sha256sum | base64 | head -c 16 ; echo'
alias nmapwi6='nmap -sP 192.168.100.0/24'

alias swapusage='for file in /proc/*/status ; do awk '"'"'/VmSwap|Name/{printf $2 " " $3}END{ print ""}'"'"' $file; done | sort -k 2 -n -r | less'

#radio pi


swap() { mv $1 tmp_switch_file; cp $2 $1; mv tmp_switch_file $2; }

ckcfg() { sudo chmod +r /dev/input/event$1; }

alias psjack='ps -e | grep jack'
alias killjack='sudo killall -9 jackdbus; killall -9 qjackctl'
alias killpulse='sudo killall -9 pulseaudio'

#if changed remeber to modify parallel_launch.sh in each parallel songs
#ctopj_solo() { chuckj song_top.ck --bufsize4096 --srate:44100; }
ctopj_solo() { chuckj song_top.ck  --srate:44100; }

ctopj() {
  #just in case there is songs remanining
  killall chuckj;

  if [ -f "parallel_launch.sh" ]; 
    then 
      ./parallel_launch.sh; 
    else 
      ctopj_solo;
    fi 
}

ctopp_solo() { chuckp song_top.ck  --srate:44100; }

ctopp() {
  #just in case there is songs remanining
  killall chuckp;

  if [ -f "parallel_launch_pulse.sh" ]; 
    then 
      ./parallel_launch_pulse.sh; 
    else 
      ctopp_solo;
    fi 
}


alias dddctopj='ddd --args chuckj ./song_top.ck --srate:44100'

ln2aux () {
  cd aux1; ln -s ../$1 . ; cd ..
  cd aux2; ln -s ../$1 . ; cd ..
  cd aux3; ln -s ../$1 . ; cd ..

  echo -1 > aux1/red/$1;
  echo -1 > aux2/red/$1;
  echo -1 > aux3/red/$1;
}


# test to keep core files in current directory


# POST Commands
# eval "$BASH_POST_RC"
# once command run, empty variable to do not replay command
# BASH_POST_RC=''
