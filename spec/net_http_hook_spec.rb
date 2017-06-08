require 'spec_helper'

RSpec.describe Aws::Xray::Hooks::NetHttp do
  before do
    Thread.abort_on_exception = true
  end

  let(:xray_client) { Aws::Xray::Client.new(sock: io) }
  let(:io) { Aws::Xray::TestSocket.new }
  let(:trace) { Aws::Xray::Trace.new(root: '1-67891233-abcdef012345678912345678') }
  let(:host) { '127.0.0.1' }
  let(:server) { TCPServer.new(0) }
  let(:port) { server.addr[1] }
  let(:queue) { Queue.new }

  def build_server_thread
    Thread.new do
      while s = server.accept
        queue.push(s.recv(1024))
        s.write("HTTP/1.1 200\r\nContent-Type: text/html\r\n\r\n\Hello world!")
        s.close
      end
    end
  end

  def build_client_thread
    Thread.new do
      Aws::Xray::Context.with_new_context('test-app', xray_client, trace) do
        Aws::Xray::Context.current.base_trace do
          queue.push(Net::HTTP.get_response(URI("http://#{host}:#{port}/")))
        end
      end

      # For waiting sending segments in this thread.
      queue.push(nil)
    end
  end

  it 'monkey patchs net/http and records requests and responses' do
    server_thread = build_server_thread
    client_thread = build_client_thread

    request_string, response, _ = queue.pop, queue.pop, queue.pop
    expect(request_string).to match(/X-Amzn-Trace-Id/)
    expect(response.code).to eq('200')

    sent_jsons = io.tap(&:rewind).read.split("\n")
    expect(sent_jsons.size).to eq(4)
    body = JSON.parse(sent_jsons[1])
    parent_body = JSON.parse(sent_jsons[3])

    expect(body['name']).to eq(host)
    expect(body['id']).to match(/\A[0-9a-fA-F]{16}\z/)
    expect(body['parent_id']).to eq(parent_body['id'])
    expect(body['trace_id']).to eq('1-67891233-abcdef012345678912345678')

    request_part = body['http']['request']
    expect(request_part['method']).to eq('GET')
    expect(request_part['url']).to eq("http://#{host}:#{port}/")
    expect(request_part['user_agent']).to match(/Ruby/)
    expect(body['http']['response']['status']).to eq(200)

    server_thread.kill
    client_thread.kill
  end
end