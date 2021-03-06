#! /usr/bin/ruby

require 'gnuplot'
require 'csv'
require 'optparse'

'''
dstat_plot
plots csv data generated by dstat
'''

$verbose = false
Y_DEFAULT = 105.0

def plot(dataset_container, category, field, dry, filename)
  Gnuplot.open do |gp|
    Gnuplot::Plot.new(gp) do |plot|
      plot.title dataset_container[:plot_title].gsub('_', '\\\\\\\\_')
      plot.xlabel 'Time in seconds'
      plot.ylabel "#{category}: #{field}"
      plot.yrange "[0:#{dataset_container[:y_max] * 1.05}]"
      plot.set 'autoscale' if dataset_container[:autoscale]
      plot.key 'out vert right top'

      unless dry
        format = filename.split('.')[-1]
        plot.terminal format + ' size 1600,800 enhanced font "Helvetica,11"'
        plot.output filename
        puts "Saving plot to '#{filename}'"
      end

      plot.data = dataset_container[:datasets]
    end
  end
end

def generate_filename(output, column, category, field, target_dir)
  generated_filename = column ? "dstat-column#{column}.png" : "#{category}-#{field}.png".sub("/", "_")
  if output
    File.directory?(output) ? File.join(output, generated_filename) : output
  else
    File.join(target_dir, generated_filename)
  end
end

# Calculate the average of groups of values from data
# Params:
# +data:: Array containing the data
# +slice_size:: number of values each group of data should contain
def average(data, slice_size)
  reduced_data = []
  data.each_slice(slice_size) do |slice|
    reduced_data.push(slice.reduce(:+) / slice.size)
  end
  reduced_data
end

# Preprocesses the data contained in all datasets in the dataset_container
# Groups of values are averaged with respect to timecode and actual data
# Params:
# +dataset_container:: Hash that holds the datasets and further information
# +slice_size:: size of the group that averages are calculated from
def data_preprocessing(dataset_container, slice_size)
  dataset_container[:datasets].each do |dataset|
    timecode = dataset.data[0]
    reduced_timecode = average(timecode, slice_size)

    values = dataset.data[1].map { |value| value.to_f }
    reduced_values = average(values, slice_size)

    dataset.data = [reduced_timecode, reduced_values]
  end
end

# Create the GnuplotDataSet that is going to be printed.
# Params:
# +timecode:: Array containing the timestamps
# +values:: Array containing the actual values
# +no_plot_key:: boolean to de-/activate plotkey
# +smooth:: nil or smoothing algorithm
# +file:: file
def create_gnuplot_dataset(timecode, values, no_plot_key, smooth, file)
  Gnuplot::DataSet.new([timecode, values]) do |gp_dataset|
    gp_dataset.with = "lines"
    gp_dataset.title = (File.basename file).gsub('_', '\\_')
    gp_dataset.notitle if no_plot_key
    gp_dataset.smooth = smooth unless smooth.nil?
  end
end

def create_plot_title(prefix, smooth, inversion, csv_header)
  plot_title = "#{prefix} over time"
  plot_title << " (smoothing: #{smooth})" if smooth
  if csv_header[2].index("Host:")
    plot_title << '\n' + "(Host: #{csv_header[2][1]} User: #{csv_header[2][6]} Date: #{csv_header[3].last})"
  end
  plot_title << '\n(inverted)' if inversion
  plot_title
end

def index_valid?(parameter, name, allowed)
  if parameter.nil?
    puts "'#{parameter}' is not a valid parameter for '#{name}'."
    puts "Allowed #{name}s: #{allowed.inspect}"
    exit 0
  else
    true
  end
end

def translate_to_column(category, field, csv)
  category_index = csv[5].index category
  index_valid?(category_index, "category", csv[5].compact)

  field_index = csv[6].drop(category_index).index field
  index_valid?(field_index, "field", csv[6].compact)
  
  if $verbose then puts "'#{category}-#{field}' was translated to #{category_index + field_index}." end
  column = category_index + field_index
end

# returns the values from a csv file
def read_data_from_csv(files, category, field, column, no_plot_key, y_max, inversion, title, smooth)
  plot_title = nil
  datasets = []
  autoscale = false
  overall_max = y_max.nil? ? Y_DEFAULT : y_max

  files.each do |file|
    csv = CSV.read(file)

    prefix = column ? "dstat-column #{column}" : "#{category}-#{field}"
    if $verbose then puts "Reading from csv to get #{prefix}." end
    
    if plot_title.nil? # this only needs to be done for the first file
      plot_title = title ? title : create_plot_title(prefix, smooth, inversion != 0.0, csv[0..6])
    end

    if csv[2].index 'Host:'
      csv = csv.drop(7)
    end

    begin
      csv = csv.transpose
    rescue IndexError => e
      puts 'ERROR: It appears that your csv file is malformed. Check for incomplete lines, empty lines etc.'
      puts e.backtrace[0] + e.message
      exit
    end

    timecode = csv[0].map { |timestamp| timestamp.to_f - csv[0].first.to_f }

    values = csv[column]
    if inversion != 0.0
      values.map! { |value| (value.to_f - inversion).abs }
      overall_max = inversion
    end
    
    if y_max.nil?
      local_maximum = values.max { |a, b| a.to_f <=> b.to_f }.to_f
      if local_maximum > overall_max then overall_max = local_maximum end
    end

    dataset = create_gnuplot_dataset(timecode, values, no_plot_key, smooth, file)
    datasets.push dataset
  end

  if $verbose then puts "datasets: #{datasets.count} \nplot_title: #{plot_title} \ny_max: #{y_max} \nautoscale: #{autoscale}" end
  { datasets: datasets, plot_title: plot_title, y_max: overall_max, autoscale: autoscale }
end

def read_options_and_arguments
  opts = {} # Hash that holds all the options

  optparse = OptionParser.new do |parser|
    # banner that is displayed at the top
    parser.banner = "Usage: \b
    dstat_plot.rb [options] -c CATEGORY -f FIELD [directory | file1 file2 ...] or \b 
    dstat_plot.rb [options] -l COLUMN [directory | file1 file2 ...]\n\n"

    ### options and what they do
    parser.on('-v', '--verbose', 'Output more information') do
      $verbose = true
    end

    opts[:inversion] = 0.0
    parser.on('-i', '--invert [VALUE]', Float, 'Invert the graph such that inverted(x) = VALUE - f(x),', 'default is 100.') do |value|
      opts[:inversion] = value.nil? ? 100.0 : value
    end

    parser.on('-n', '--no-key', 'No plot key is printed.') do
      opts[:no_plot_key] = true
    end

    parser.on('-d', '--dry', 'Dry run. Plot is not saved to file but instead displayed with gnuplot.') do
      opts[:dry] = true
    end

    parser.on('-o', '--output FILE|DIR', 'File or Directory that plot should be saved to. ' \
      'If a directory is given', 'the filename will be generated. Default is csv file directory.') do |path|
      opts[:output] = path
    end

    parser.on('-y', '--y-range RANGE', Float, 'Sets the y-axis range. Default is 105. ' \
      'If a value exceeds this range,', '"autoscale" is enabled.') do |range|
      opts[:y_max] = range
    end

    parser.on('-t', '--title TITLE', 'Override the default title of the plot.') do |title|
      opts[:title] = title
    end

    parser.on('-s', '--smoothing ALGORITHM', 'Smoothes the graph using the given algorithm.') do |algorithm|
        algorithms = %w(unique frequency cumulative cnormal kdensity unwrap csplines acsplines mcsplines bezier sbezier)
        if algorithms.index(algorithm)
          opts[:smooth] = algorithm
        else
          puts "#{algorithm} is not a valid option as an algorithm."
          exit
        end
    end

    parser.on('-a', '--average-over SLICE_SIZE', Integer, 'Calculates the everage for slice_size large groups of values.', "\n") do |slice_size|
      opts[:slice_size] = slice_size
    end

    parser.on('-c', '--category CATEGORY', 'Select the category.') do |category|
      opts[:category] = category
    end

    parser.on('-f', '--field FIELD' , 'Select the field.') do |field|
      opts[:field] = field
    end

    parser.on('-l', '--column COLUMN', 'Select the desired column directly.', "\n") do |column|
      unless opts[:category] && opts[:field]  # -c and -f override -l
        opts[:column] = column.to_i
      end
    end

    # This displays the help screen
    parser.on_tail('-h', '--help', 'Display this screen.' ) do
      puts parser
      exit
    end
  end

  # there are two forms of the parse method. 'parse'
  # simply parses ARGV, while 'parse!' parses ARGV
  # and removes all options and parameters found. What's
  # left is the list of files
  optparse.parse!
  if $verbose then puts "opts: #{opts.inspect}" end

  if opts[:category].nil? || opts[:field].nil?
    if opts[:column].nil?
      puts "[Error] (-c CATEGORY and -f FIELD) or (-l COLUMN) are mandatory parameters.\n\n #{optparse}"
      exit
    end
  end

  # if ARGV is empty at this point no directory or file(s) is specified
  # and the current working directory is used
  if ARGV.empty? then ARGV.push '.' end

  files = []
  if File.directory?(ARGV.last)
    opts[:target_dir] = ARGV.last.chomp('/') # cuts of "/" from the end if present
    files = Dir.glob "#{opts[:target_dir]}/*.csv"
    files = files.sort
  else
    opts[:target_dir] = File.dirname ARGV.first
    ARGV.each { |filename| files.push filename }
  end
  puts "Plotting data from #{files.count} file(s)."
  opts[:files] = files
  if $verbose then puts "files: #{files.count} #{files.inspect}" end

  # opts = { :inversion, :no_plot_key, :dry, :output, :y_max, :title, :category, :field, :column, :target_dir, :files }
  opts
end

if __FILE__ == $0
  opts = read_options_and_arguments
  dataset_container = read_data_from_csv(opts[:files],opts[:category], opts[:field], opts[:column],
    opts[:no_plot_key], opts[:y_max], opts[:inversion], opts[:title], opts[:smooth])
  data_preprocessing(dataset_container, opts[:slice_size]) unless opts[:slice_size].nil?
  filename = generate_filename(opts[:output], opts[:column], opts[:category], opts[:field], opts[:target_dir])
  plot(dataset_container, opts[:category], opts[:field], opts[:dry], filename)
end
