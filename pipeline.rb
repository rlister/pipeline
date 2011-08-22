#!/usr/bin/env ruby

require 'rubygems'
require 'socket'
require 'optparse'
require 'progressbar'

scriptname = File::basename($0)
usage = "Usage: #{scriptname} [options] filename host1 [host2 [host3 [...]]]"

## defaults
port = 31337
output = nil
fifo = "/tmp/#{scriptname}.fifo"
ssh = "ssh"
login = nil

## cmdline options
OptionParser.new do |opt|
  opt.banner = usage
  opt.on("-f", "--fifo NAME", "Filename for fifo.")                    { |f| fifo = f }
  opt.on("-o", "--output FILENAME", "Output filename.")                { |o| output = o }
  opt.on("-p", "--port NUMBER", "Port number for all netcats.")        { |p| port = p }
  opt.on("-l", "--login LOGIN_NAME", "Username for all ssh commands.") { |l| login = l }
  opt.on_tail("-h", "--help", "Show this message.") do
    puts opt
    exit
  end
end.parse!

ssh << " -l #{login}" if login

## must have filename and at least 2 hosts
raise ArgumentError, usage unless ARGV.length >= 2
filename = ARGV.shift
hosts = ARGV

input = File.open(filename) or raise IOError, "failed to open input file #{filename}" # local input file
output ||= File::basename(filename) # remote output file

## lay some pipe
(hosts.size - 1).downto(0).each do |i|
  host, next_host = hosts.slice(i, 2)
  puts "setting up: #{[host, next_host].compact.join(' -> ')}"
  
  if next_host # connect host to the next one in the chain
    script=<<-SCRIPT.gsub(/^\s*/, '')
      rm -f #{fifo};
      mkfifo #{fifo};
      pkill -f '^nc.*#{port}';
      nc #{next_host} #{port} < #{fifo} &
      nc -l #{port} | tee #{fifo}>#{output}
    SCRIPT
  else                          # last host in chain
    script=<<-SCRIPT.gsub(/^\s*/, '')
      pkill -f '^nc.*#{port}';
      nc -l #{port} > #{output}
    SCRIPT
  end

  fork { exec "#{ssh} #{host} '#{script}'" } # fork long-lived netcat process on remote host
  sleep 0.5                               # give it a chance to start
  #puts "SCRIPT: '#{script}'"
end

## make sure we clean up procs on ctrl-c
Kernel.trap('INT') { Process.wait }

## give the chain time to start up
sleep 2

## progress bar
size = File.size(filename)
bar = ProgressBar.new("Copying", size)
bar.file_transfer_mode

## connect to first host in chain and start to send data
sock = TCPSocket.new(hosts.first, port) or raise SocketError, "failed to get socket #{hosts.first}:#{port}"
begin
  while ( (data = input.read_nonblock(100)) != "")
    sock.write(data)
    bar.inc(100)
  end
rescue Errno::EAGAIN
rescue EOFError  # STDIN throws EOFError when done with input
  input.close
  sock.close
end

bar.finish

## mop up child procs
puts "waiting for child ssh processes to exit"
Process.wait

## clean up, and sanity check remote file size
hosts.each do |host|
  script=<<-SCRIPT
    rm -f #{fifo};
    pkill -f '^nc.*#{port}';
    ls -l #{output}
  SCRIPT
  ls_l = %x[#{ssh} #{host} '#{script}']
  puts "#{host}: #{ls_l}"
end
