require 'sinatra'
require 'yaml'

require_relative 'services/dmphub/data_management_plan_service'
require_relative 'services/nsf/awards_scanner_service'

configure do
  p Dir.pwd
  set config: YAML.load(File.open("#{Dir.pwd}/config.yml"))
end

get '/' do
  erb :index
end

get '/scan' do
  dmphub = Dmphub::DataManagementPlanService.new(
    config: settings.config['dmphub']
  )
  nsf = Nsf::AwardsScannerService.new(
    config: settings.config['nsf']
  )
  processed = JSON.parse(File.read("#{Dir.pwd}/processed.yml"))
  scanned = []

  stream do |out|
    plans = dmphub.data_management_plans
    out << 'No DOIs found<br>' if plans.empty?

    plans.each do |plan|
      doi = plan['uri'].gsub('http://localhost:3003/api/v1/data_management_plans/', '')

#next unless ['10.80030/9ddh-tf78', '10.80030/0cd0-ce69', '10.80030/yxcw-kh07'].include?(doi)
next unless ['10.80030/yxcw-kh07'].include?(doi)

      next if processed.include?(plan['uri'])

      out << "Scanning Awards API for DMP: `#{plan['title']}` (#{doi})<br>"
      out << "&nbsp;&nbsp;&nbsp;&nbsp;with author(s): #{plan['authors'].gsub('|', ' from ')}<br>"

      award = nsf.find_award_by_title(plan: plan)
      scanned << plan['uri']

      out << '&nbsp;&nbsp;no matches found<br>' if award.empty?
      if award.any?
        out << "&nbsp;&nbsp;<strong>Found award</strong>: <a href=\"#{award[:award_id]}\">#{award[:award_id]}</a><br>"
        out << "&nbsp;&nbsp;&nbsp;&nbsp;<strong>Title</strong>: #{award[:title]}<br>"
        award[:principal_investigators].each do |pi|
          out << "&nbsp;&nbsp;&nbsp;&nbsp;<strong>Investigator</strong>: #{pi[:name]} from #{pi[:organization]}<br>"
        end

        out << "<br>&nbsp;&nbsp;Sending award information back to the DMPHub<br>"
        if dmphub.register_award(dmp: plan, award: award)
          out << "&nbsp;&nbsp;&nbsp;&nbsp;Sucess"
        else
          out << "&nbsp;&nbsp;&nbsp;&nbsp;Something went wrong"
        end
      end
      out << "<hr>"
    end
  end

  # Always write out the processed file even if code is interrupted!
  file = File.open("#{Dir.pwd}/processed.yml", 'w')
  file.write((processed + scanned).flatten.uniq)
  file.close
end