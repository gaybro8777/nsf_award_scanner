require 'httparty'
require 'amatch'
require 'stopwords'

module Nsf
  # This service uses the NSF Award Search Web API (ASWA). For more information
  # refer to: https://www.nsf.gov/developer/
  class AwardsScannerService

    SHOW_AWARD_URL = 'https://www.nsf.gov/awardsearch/showAward?AWD_ID='.freeze

    include Amatch

    def initialize(config:)
      @agent = "California Digital Library (CDL) - contact: brian.riley@ucop.edu"

      @base_path = "#{config['base_path']}"
      @awards_path = "#{@base_path}#{config['awards_path']}?keyword=%{words}"
      @errors = []
    end

    def find_award_by_title(plan:)
      return nil if plan.nil? || plan.fetch('title', nil).nil?

      url = "#{@awards_path}" % { words: cleanse_title(title: plan['title']) }
      url = URI.encode(url.gsub(/\s/, '+'))

      resp = HTTParty.get(url, headers: headers)
      p "Received a #{resp.code} from the NSF Awards API for: #{url}" unless resp.code == 200
      p resp.body unless resp.code == 200
      return nil unless resp.code == 200

      payload = JSON.parse(resp.body)
      scores = []
      payload.fetch('response', {}).fetch('award', []).each do |award|
        next if award.fetch('title', nil).nil? || award.fetch('piLastName', nil).nil?

        score = process_response(
          plan: plan,
          title: award.fetch('title', nil),
          pi: "#{award.fetch('piFirstName', nil)} #{award.fetch('piLastName', nil)}",
          org: award.fetch('awardeeName', nil)
        )
        scores << { score: score, hash: award } if score >= 0.9
      end
      filter_scores(scores: scores)
    end

    def parse_author(author:)
      return nil if author.nil?
      parts = author.split('|')
      { author: parts.first, organization: parts.last }
    end

    private

    def headers
      {
        'User-Agent': 'California Digital Library (CDL) - contact: brian.riley@ucop.edu',
        'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
        'Accept': 'application/json'
      }
    end

    def filter_scores(scores:)
      return nil unless scores.any?

      top_score = scores.sort { |a, b| b.fetch(:score, 0.0)<=>a.fetch(:score, 0.0) }.first
      top_score_title = top_score.fetch(:hash, {}).fetch('title', '')

      pis = scores.select { |s| s.fetch(:hash, {}).fetch('title', '') == top_score_title }
                  .collect do |s|
                    names = [
                      s.fetch(:hash, {}).fetch('piFirstName', ''),
                      s.fetch(:hash, {}).fetch('piLastName', '')
                    ]

                    {
                      name: names.join(' '),
                      organization: s.fetch(:hash, {}).fetch('awardeeName', '')
                    }
                  end
      {
        title: top_score_title,
        principal_investigators: pis,
        award_id: "#{SHOW_AWARD_URL}#{top_score.fetch(:hash, {}).fetch('id', '')}"
      }
    end

    def process_response(plan:, title:, pi:, org:)
      title_score = proximity_check(
        text_a: cleanse_title(title: plan.fetch('title', nil)),
        text_b: cleanse_title(title: title)
      )
      return title_score if plan.fetch('authors', nil).nil?

      persons = plan.fetch('authors', '').split(', ')
      pi_score = persons.reduce(0.0) { |sum, p| sum + proximity_check(text_a: p, text_b: pi) }


      return 0.0 if plan.nil? || title.nil?

      auth_hash = plan.fetch('authors', '').split(', ').map { |a| parse_author(author: a) }
      auths = auth_hash.collect { |a| a[:author] }
      orgs = auth_hash.collect { |o| o[:organization] }

      title_score = title_scoring(
        title_a: cleanse_title(title: plan.fetch('title', nil)),
        title_b: cleanse_title(title: title)
      )
      return title_score if (orgs.empty? && auths.empty?) || title_score < 0.7

      pi_org_score = org_scoring(orgs: orgs, pi_org: org)
      pi_score = author_scoring(authors: auths, pi: pi)
      title_score + pi_score + pi_org_score
    end

    def title_scoring(title_a:, title_b:)
      return 0.0 if title_a.nil? || title_b.nil?

      proximity_check(
        text_a: cleanse_title(title: title_a),
        text_b: cleanse_title(title: title_b)
      )
    end

    def org_scoring(orgs:, pi_org:)
      return 0.0 if orgs.empty? || pi_org.nil?

      orgs.reduce(0.0) { |sum, org| sum + proximity_check(text_a: org, text_b: pi_org) }
    end

    def author_scoring(authors:, pi:)
      return 0.0 if authors.empty? || pi.nil?

      authors.reduce(0.0) { |sum, auth| sum + proximity_check(text_a: auth, text_b: pi) }
    end

    def cleanse_title(title:)
      # DMPs ofter start with a name of the grant type (e.g. 'EAGER:'') so strip these off
      ret = title.include?(':') ? title.split(':').last : title
      # Remove non alphanumeric, space or dash characters
      ret = ret.gsub!(/[^0-9a-z\s\-]/i, '') if ret.match?(/[^0-9a-z\s\-]/i)
      # If ret is nil for any reason just use the unaltered title
      ret = title if ret.nil?
      # Remove stop words like 'The', 'An', etc.
      ret.split(' ').select { |w| !Stopwords.is?(w) }.join(' ')
    end

    def proximity_check(text_a:, text_b:)
      return nil if text_a.nil? || text_b.nil?

      text_a.to_s.levenshtein_similar(text_b.to_s)
    end
  end
end
