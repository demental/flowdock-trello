require 'rubygems'
require 'faraday'
require 'json'
require 'time'

$stdout.sync = true

trello_organization = ENV['TRELLO_ORGANIZATION']
trello_key = ENV['TRELLO_KEY']
trello_token = ENV['TRELLO_TOKEN']
trello_actions = ENV['TRELLO_ACTIONS'].split(',')
flowdock_token = ENV['FLOWDOCK_TOKEN']
flowdock_email = ENV['FLOWDOCK_EMAIL']

def text_to_html(text)
  start_tag = '<p>'
  text = text.to_str
  text.gsub!(%r/\r\n?/, "\n")
  text.gsub!(%r/\n\n+/, "</p>\n\n#{start_tag}")
  text.gsub!(%r/([^\n]\n)(?=[^\n])/, '\1<br />')
  text.insert 0, start_tag
  text << '</p>'
end

trello = Faraday.new(:url => 'https://api.trello.com') do |faraday|
  faraday.request :url_encoded
  faraday.adapter Faraday.default_adapter
end

flowdock = Faraday.new(:url => 'https://api.flowdock.com') do |faraday|
  faraday.request :url_encoded
  faraday.adapter Faraday.default_adapter
end

trello_boards = {}
while true
  response = trello.get "/1/organizations/#{trello_organization}/boards?key=#{trello_key}&token=#{trello_token}"
  results = JSON.parse(response.body)
  results.each do |board|
    board_id = board['id']
    if board['closed']
      trello_boards.delete(board_id)
    else
      trello_boards[board_id] ||= {'id' => board['id']}
    end
  end

  trello_boards.values.each do |trello_board|
    board_id = trello_board['id']
    last_time = trello_board['last_time']

    begin
      response = trello.get "/1/boards/#{board_id}/actions?key=#{trello_key}&token=#{trello_token}"
      results = JSON.parse(response.body)
      results.reverse!
      
      if last_time
        results.each do |result|
          begin
            next if Time.parse(result['date']) <= last_time
            puts result.inspect
            
            data = result['data']
            source = 'Trello'
            action = nil
            from = result['memberCreator']['fullName']
            from_address = flowdock_email
            project = data['board']['name'].gsub(/[^\w\s]/, '_')
            board_id = data['board']['id']
            board_link = "https://trello.com/board/#{board_id}"
            card_data = data['card'] || {}
            card_link = "https://trello.com/card/#{board_id}/#{card_data['idShort']}"
            card_name = card_data['name']
            case result['type']
            when 'addMemberToCard'
              action = 'addMemberToCard'
              subject = "Added #{result['member']['fullName']} to: #{card_name}"
              content = card_name
            when 'commentCard'
              action = 'commentCard'
              subject = "Commented on: #{card_name}"
              content = data['text']
            when 'createCard'
              action = 'createCard'
              subject = "Created: #{card_name}"
              content = card_name
            when 'removeMemberFromCard'
              action = 'removeMemberFromCard'
              subject = "Removed #{result['member']['fullName']} from: #{card_name}"
              content = card_name
            when 'updateCard'
              if data['listAfter'] && data['listBefore']['name'] != data['listAfter']['name']
                action = 'updateCardList'
                subject = "Moved to #{data['listAfter']['name']}: #{card_name}"
              elsif data['old'] && data['old']['desc']
                action = 'updateCardDescription'
                subject = "Updated description for: #{card_name}"
              elsif data['old'] && data['old']['name']
                action = 'updateCardName'
                subject = "Updated name for: #{card_name}"
              elsif data['old'] && !data['old']['closed'].nil?
                action = 'updateCardClosed'
                if data['old']['closed']
                  subject = "Reopened: #{card_name}"
                else
                  subject = "Archived: #{card_name}"
                end
              else
                next
              end
              content = data['card']['desc'] || 'Updated'
            when 'updateCheckItemStateOnCard'
              action = 'updateCheckItemStateOnCard'
              subject = "Updated #{data['checkItem']['name']} on: #{card_name}"
              content = "State: #{data['checkItem']['state'] || 'incomplete'}"
            else
              next
            end
            content = text_to_html(content)
            
            if trello_actions.include?(action)
              flowdock.post "/v1/messages/team_inbox/#{flowdock_token}", {
                :source => source,
                :from_address => from_address,
                :subject => subject,
                :content => content,
                :from_name => from,
                :project => project,
                :format => 'html',
                :link => card_link
              }
            end
          rescue Exception => ex
            puts ex.message
            puts ex.backtrace * "\n"
          end
        end
      else
        puts "Skipping #{board_id}"
      end
      
      # Set last time of most recent result
      results.each do |result|
        timestamp = Time.parse(result['date'])
        trello_board['last_time'] = last_time ? [last_time, timestamp].max : timestamp
      end
    rescue Exception => ex
      puts ex.message
      puts ex.backtrace * "\n"
    end
  end

  sleep 60
end
