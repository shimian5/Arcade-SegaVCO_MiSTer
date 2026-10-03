# kills ONLY this project's audio sims (never anything under ./verilator/ or other projects)
for p in $(ps -eo pid,args | grep -E 'obj_dir_audio/Vaudio_top|sim/run_s[0-9a-z]+\.sh|make audio|make -C obj_dir_audio' | grep -v grep | grep -v killsim | awk '{print $1}'); do kill -9 $p 2>/dev/null; done
echo killed-audio-only
