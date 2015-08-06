#! /usr/bin/ruby

require 'gnuplot'
require 'csv'
require 'optparse'

"""
dstat_plot
plots csv data generated by dstat-monitor
""" 

$verbose = false

def plot(dataset_container, category, field, dry, target_dir)
  Dir.chdir(target_dir)

  Gnuplot.open do |gp|
    Gnuplot::Plot.new(gp) do |plot|
      plot.title dataset_container[:plotTitle]
      plot.xlabel "Time in seconds"
      plot.ylabel "#{category}: #{field}"
      range_max = dataset_container[:y_range][:max]
      plot.yrange "[0:#{range_max}]"
      if dataset_container[:autoscale] then plot.set "autoscale" end
      plot.key "out vert right top"
      
      unless dry
        plot.terminal 'png size 1600,800 enhanced font "Helvetica,11"'
        filename = "#{category}-#{field}.png".sub("/", "_")
        plot.output filename
        puts "Saving plot to '#{target_dir}/#{filename}'"
      end

      plot.data = dataset_container[:datasets]
    end
  end
end

def read_csv(category, field, files, no_plot_key, y_range)
  if $verbose then puts "Reading from csv." end

  plotTitle = "#{category}-#{field} over time" + ' \n '
  plotTitleNotSet = true

  datasets = []
  autoscale = false

  files.each do |file|
    CSV.open(file) do |csvFile|
      currentRow = csvFile.shift
      # loop until row with "epoch" in it is reached and read some meta data 
      # but only for the first file since there can only be one title
      while currentRow.index("epoch").nil? do
        if plotTitleNotSet
          if currentRow.index("Host:") != nil
            plotTitle += "(Host: #{currentRow[1]} User: #{currentRow[6]}"
          elsif currentRow.index("Cmdline:") != nil
            plotTitle += " Date: #{currentRow.last})"
            plotTitleNotSet = false
          end
        end
        currentRow = csvFile.shift
      end

      # find the epoch category == nil if not found
      epoch_index = currentRow.index("epoch")

      categoryIndex = currentRow.index(category)
    	if categoryIndex.nil?
    		puts "#{category} is not a valid parameter for 'category'. Value could not be found."
        puts "Allowed categories: #{currentRow.inspect}"
    		exit 1
    	end
    	
    	currentRow_at_category = csvFile.shift.drop(categoryIndex)
      field_offset = currentRow_at_category.index(field)
    	if field_offset.nil?
    		puts "#{field} is not a valid parameter for 'field'. Value could not be found."
        puts "Allowed fields: #{currentRow.inspect}"
    		exit 1
      else
        fieldIndex = categoryIndex + field_offset
    	end

      # get all the interesting values and put them in an array
    	currentRow = csvFile.shift
      unless epoch_index.nil? then time_offset = currentRow.at(epoch_index).to_f end
      timecode = []
      values = []
      until csvFile.eof do
        values.push currentRow.at(fieldIndex)
        unless epoch_index.nil? then timecode.push(currentRow.at(epoch_index).to_f - time_offset) end
        if !y_range[:enforced]
          if values.last.to_f >= y_range[:max] then autoscale = true end
        end
        currentRow = csvFile.shift
      end

      if epoch_index.nil? then timecode = (0..values.count - 1).to_a end

      # create the GnuplotDataSet that is going to be printed
      dataset = Gnuplot::DataSet.new([timecode, values]) do |gp_dataSet|
        gp_dataSet.with = "lines"
        if no_plot_key then
          gp_dataSet.notitle
        else
          gp_dataSet.title = File.basename file
        end
      end

      datasets.push dataset
    end
  end

  if $verbose then puts "datasets: #{datasets.count} \nplotTitle: #{plotTitle} \ny_range: #{y_range} \nautoscale: #{autoscale}" end

  dataset_container = {:datasets => datasets, :plotTitle => plotTitle, :y_range => y_range, :autoscale => autoscale}
end


def read_options_and_arguments
  options = {} # Hash that hold all the options

  optparse = OptionParser.new do |opts|
    # banner that is displayed at the top
    opts.banner = "Usage: dstat_plot.rb [options] -c CATEGORY -f FIELD [directory | file1 file2 ...]"

    ### options and what they do
    opts.on('-v', '--verbose', 'Output more information') do
      $verbose = true
    end

    options[:inverted] = false
    opts.on('-i', '--inverted', 'Invert the graph') do
      options[:inverted] = true
    end

    options[:no_plot_key] = false
    opts.on('-n','--no-key', 'No plot key is printed') do
      options[:no_plot_key] = true
    end

    options[:dry] = false
    opts.on('-d', '--dry', 'Dry run. Plot is not saved to file but displayed with gnuplot') do
      options[:dry] = true
    end

    options[:output] = nil
    opts.on('-o','--output PATH', 'Path where the graph should be saved to, default is csv file directory') do |path|
      options[:output] = path
    end

    options[:y_range] = {:max => 105.0, :enforced => false}
    opts.on('-y', '--y-range RANGE', 'Sets the y-axis range. Default is 105 or "autoscale" if a value exceeds the set range') do |range|
      options[:y_range] = {:max => range.to_f, :enforced => true}
    end

    options[:category] = nil
    opts.on('-c', '--category CATEGORY', 'Select the category') do |category|
      options[:category] = category
    end

    options[:field] = nil
    opts.on('-f', '--field FIELD' , 'Select the field') do |field|
      options[:field] = field
    end

    # This displays the help screen
    opts.on('-h', '--help', 'Display this screen' ) do
      puts opts
      exit
    end
  end

  # there are two forms of the parse method. 'parse' 
  # simply parses ARGV, while 'parse!' parses ARGV 
  # and removes all options and parameters found. What's
  # left is the list of files
  optparse.parse!
  if $verbose then puts "options: #{options.inspect}" end
  
  # if ARGV is empty at this point no directory or file(s) is specified
  # and the current working directory is used
  if ARGV.empty? then ARGV.push "." end

  files = []
  if File.directory?(ARGV.last) then
    options[:target_dir] = ARGV.last.chomp("/") # cuts of "/" from the end if present
    files = Dir.glob "#{options[:target_dir]}/*.csv"
  else
    options[:target_dir] = File.dirname ARGV.first
    ARGV.each do |filename|
      files.push filename
    end
  end
  puts "Plotting data from #{files.count} file(s)."
  options[:files] = files
  if $verbose then puts "files: #{files.count} #{files.inspect}" end

  if options[:output] != nil then # if an output directory is explicitly stated
    options[:target_dir] = options[:output].chomp("/")
  end

  options
end

options = read_options_and_arguments
dataset_container = read_csv(options[:category], options[:field], options[:files], options[:no_plot_key], options[:y_range])
plot(dataset_container, options[:category], options[:field], options[:dry], options[:target_dir])
