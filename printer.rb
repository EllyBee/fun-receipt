#MARTEL PRINTER RUBY IMPLEMENTATION
@version = "v0.7"
#Andy Huntington 19th Sept 2014

#needed for application config
require 'trollop'
#needed for buttons/network_ledS
require 'wiringpi2'
#needed for printing
require 'cairo'
require 'serialport'
require "open-uri"
require "logging"

opts = Trollop::options do
    opt :flipped, "flip the image", :default => true
    opt :forcecompress, "force compression"
    opt :usegpio, "use gpio for control", :default => true
    opt :image, "image name"
	opt :useimagesfolder, "use the predefined folder of images", :default => true
	opt :loglevel, "the log level", :default => "warn", :type => :string
end

Logging.color_scheme( 'bright',
                     :levels => {
                     :info  => :green,
                     :warn  => :yellow,
                     :error => :red,
                     :fatal => [:white, :on_red]
                     },
                     :date => :blue,
                     :logger => :cyan,
                     :message => :magenta
                     )

Logging.appenders.stdout(
                         'stdout',
                         :layout => Logging.layouts.pattern(
                                                            :pattern => '[%d] %-5l %c: %m\n',
                                                            :color_scheme => 'bright'
                                                            )
                         )

Signal.trap('TERM') {
	@log.warn "in the TERM trap"
	@shouldRun = false
}

Signal.trap('INT') {
	@log.warn "in the INT trap"
	@shouldRun = false
}

def encode_martel_rle(img, print_flag)
	
	#check for a locally encoded file
	img = @imagesSubDir+img
	
	# encode the file if there isn't one, or if we're forcing compression, or we've just downloaded something which might have the same filename.
	if ((not File.exist?(img+@flipString+".bin") && !@compress) or !print_flag)
        
		@log.debug "Loading image..." + img
		
		s = Cairo::ImageSurface.from_png(open(img))
		
		if @flipString == ""
			@unpacked_image_data = s.data.unpack("C*")
            else
			
			@log.debug  "rotating the image"
            flipped_surface = Cairo::ImageSurface.new(Cairo::FORMAT_ARGB32, s.width, s.height)
            flipped_ctx = Cairo::Context.new(flipped_surface)
            
            # Make sure the destination surface is white
            flipped_ctx.set_source_color("#ffff")
            flipped_ctx.paint()
            
            # Set the origin up correctly for our rotation by translating to the mid point
            flipped_ctx.translate(s.width / 2.0, s.height / 2.0)
            flipped_ctx.rotate(Math::PI)
            flipped_ctx.translate(-s.width / 2.0, -s.height / 2.0)
            flipped_ctx.set_source(s, 0, 0)
            flipped_ctx.paint()
            
			# flipped_surface.write_to_png("flipped.png")
            
            @unpacked_image_data = flipped_surface.data.unpack("C*")
		end
		
		
		@log.debug  "unpacked image, start encoding"
		# puts @unpacked_image_data.length
		# hard coded for local testing...
		@channels = 4
		@image_width = 384
		@rows = (@unpacked_image_data.length / @image_width) / @channels
        
		@threshold = 127
        
		@buffer = []
		@data = ""
        
		@total_pixel_count = @rows*@image_width
        
		@total_byte_count = @total_pixel_count * @channels
        
		@imgH = (@total_pixel_count/8)/48 # should be the n bytes/48.
        
		@leading_space = 0
        
		y = 0
        
		# // max is 24*255 = 6120 pixel lines.
		@num_lines = [(@imgH + 23 ) / 24, 255].min
        
		#	loop for each character line
		while y < @imgH do
			#puts "processing row #{y}"
            
			if y % 24 == 0
				#puts "setting compressed bit sequence"
				addToData(27)
				addToData('Z')
			end
			
			#		 /*
			#			get the color of the first pixel in the line
			#			*/
			#puts "getting first pixel"
			black	= isBlack( 0, y );
			#puts "got first pixel and it is #{black}"
			pixels = 1;
			#			/*
			#			start at position 4, so that we can put the line
			#			byte length, and the leading spaces in the end
			#			*/
			index = 4;
			#puts "index = #{index}"
			#		 /*
			#			for each pixel in the line
			#			*/
			x = 0
			while x < (@image_width-1)
				x=x+1 # no inbuilt iterator in the while!
				#		for x in 1..(@image_width-1)
				if pixels > 62
					# the maximum run length is 63 dots.
					# puts "pixels count= #{pixels}"
					@buffer[index] = ( black ? 0x40 : 0x00 ) + ( pixels & 0x3F )
					index=index+1
					#puts "long run prev black = #{black}"
					black = isBlack(x, y)
					#puts "long run next black = #{black}"
					pixels = 1
                    elsif black != isBlack(x, y)
					#						 /*
					#							color has changed, so write a field. If there are
					#							less than 8 pixels, then it is more efficient to
					#							write a bitmap field instead of a RLE field.
					#							*/
					#puts "pixel changed #{x},#{y}"
					if pixels < 8
						#								 /*
						#									Encode 7 bits into a 7-dot fields.
						#									*/
						bits=0
						for i in 0..6
							#puts "bit #{i}"
							bits = bits << 1
							if isBlack((x-pixels)+i, y)
								bits = bits | 0x01
							end
						end
                        
						# puts "pre buffer set #{index}, pixels = #{pixels}"
						@buffer[index] = 0x80 | bits
						index=index+1
						#puts "post buffer set #{index}"
						x=x+7-pixels
						#puts "x set to #{x}"
                        else
						#								 /*
						#									sensible number of pixels, so write a RLE
						#									field
						#									*/
						#puts "RLE write out at index #{index}, x = #{x}, y = #{y})"
						@buffer[index] =	( black ? 0x40 : 0x00 ) + ( pixels & 0x3F )
						index=index+1
					end
                    
					#puts "check following RLE write out (pixels = #{pixels}, x = #{x}, y = #{y})"
					black = isBlack(x,y)
					pixels = 1
					#puts "check following RLE write out pixels reset to #{pixels}"
                    else
					pixels = pixels+1
					#				 else // pixel is same as last one
				end
				#
				#puts "ending of loop x = #{x}, y = #{y}"
			end
			#	 // end for each column byte x
			#
			if pixels > 0
				#puts "pixels = #{pixels}, #{@x}, #{y})"
				@buffer[index] =	( black ? 0x40 : 0x00 ) + ( pixels & 0x3F )
				index=index+1
				#
				#		 /*
				#			strip trailing whitespace from line
				#			*/
                
				while ( ( ( @buffer[ index-1 ] & 0xC0 ) == 0x00 ) && index > 4 ) do
					index=index-1
				end
				#
				@buffer[0] = index - 1
                
				leading_space = ( 384 - @image_width ) / 2
				leading_space = [leading_space/3, 63].min
				#		 buffer[ 1 ] = (Byte)leading_space;	// white pixels at start of image
				#		 buffer[ 2 ] = (Byte)leading_space;	// white pixels at start of image
				#		 buffer[ 3 ] = (Byte)leading_space;	// white pixels at start of image
                
				@buffer[ 1 ] = leading_space
				@buffer[ 2 ] = leading_space
				@buffer[ 3 ] = leading_space
                
				#
				# grimmest optimisation
				# a clear white line is encoded as 3,0,0,0 but should more optimally be 1,0
				if @buffer[0..3] == [3,0,0,0]
					@buffer[0] = 1
				end
                
                
				for c in 0..@buffer[0]
					#puts "adding data for index #{c}"
					addToData(@buffer[c])
				end
				#
				#		 /*
				#			print a line-feed to eject the line.
				#			*/
				if (y % 24) == 23
					addToData(10)
				end
				# } // end for each line (y)
                end
                y=y+1
            end
            # /*
            #	how many row left of last character line?
            #	*/
			
            lines_left = (24-(@imgH%24))%24
            # y = ( 24 - ( imgH % 24 ) ) % 24;
            #
            
            if lines_left > 0
                while lines_left > 0
                    #puts "lines_left = #{lines_left.inspect}"
                    lines_left = lines_left-1
                    addToData(0x01)
                    addToData(0x00)
                end
            end
            @log.debug "Encoded"
            
            sendToPrinter(@data) unless print_flag == false
            
            if @flip
                flippedString = "flipped"
                else
                flippedString = ""
            end
            File.open(img+@flipString+".bin", 'w') { |file| file.write(@data) }
            @log.debug "Written"
            else
            @log.debug "already encoded, using "+img+@flipString+".bin"
            dataf = File.open(img+@flipString+".bin", 'r')
            @data = dataf.read
            #sp.write("already encoded\r\r\r")
            sendToPrinter(@data) unless print_flag == false
        end
        
        end
        
        def sendToPrinter(data)
        @sp.write(@data)
        @log.debug "finished sending data"
    end
    
    def connectPrinter
        port_str = "/dev/ttyACM0"	#may be different for you
        baud_rate = 115200
        data_bits = 8
        stop_bits = 1
        parity = SerialPort::NONE
		
        @log.debug "Opening serial comms"
        @sp = SerialPort.new(port_str, baud_rate, data_bits, stop_bits, parity)
        @sp.flow_control = SerialPort::HARD
        @log.debug "Opened serial comms"
    end
    
    def disconnectPrinter
        @log.debug "Closing serial port"
        #@sp.close unless @sp==nil
        @sp.close
    end
    
	
    def addToData(b)
        #puts "adding #{b.ord}"
        @data << b
        #puts "DATA = #{b}"
    end
	
	
    def isBlack(thex, they)
        
        current_pixel_is_black = false;
        # the data comes in as an array of bytes. each a r, g, b or alpha
        byte_offset = @channels * ((@image_width * they)+thex);
        #puts "check #{thex},#{they} #{byte_offset}"
        @current_pixel_number = byte_offset / @channels
		
        r = @unpacked_image_data[byte_offset]
        g = @unpacked_image_data[byte_offset+1]
        b = @unpacked_image_data[byte_offset+2]
        if @channels == 4
            a = @unpacked_image_data[byte_offset+3]
            else
            a = nil
        end
        
        # In printer output terms, 0 = white, 1 = black.
        # If we have all zeroes for the input pixel RGBA, then set it white, as this is 'transparent'
        # and 100% transparent things on a white bit of paper are....white!
        
        if a && a == 0 && r == 0 && g == 0 && b == 0
            current_pixel_is_black = false
            elsif r > @threshold || g > @threshold || b > @threshold
            current_pixel_is_black = false
            else
            current_pixel_is_black = true
        end
        
        return current_pixel_is_black
    end
    
    
    def getNextImage(currentImage)
        #get the index of the current image
        #puts @theImages.inspect
        #puts currentImage.inspect
        img=""
        #default to the first item if you've never printed before, or you've removed items from the list due to an update.
        if currentImage == nil or @theImages.index(currentImage) == nil
            img = @theImages[0]
            else
            ind = @theImages.index(currentImage)
            #puts "current image index = "+ind.inspect
            #puts "current image index = "+ind+", next image index = "+((ind % @theImages.length) + 1).to_s
            img = @theImages[(ind + 1) % @theImages.length]
        end
        
        return img
    end
    
    
    
    def checkRemote(theURL, localDir)
        
        begin
            #both these lists are local to this function so don't confuse them with the ones outside!
            remoteList = []
            localList = []
            #OPEN THE REMOTE FILE
            open(theURL+"images.txt").read.each_line do |line|
                remoteList << line.strip
            end
            
            #OPEN THE LOCAL LIST AND CHECK IF IT IS DIFFERENT
            File.open(@imagesSubDir+"images.txt").each_line do |line|
                localList << line.strip
            end
            
            if localList==remoteList
                #log.debug "No change in remote files"
                else
                # Things have changed so download the new files.
                remoteList.each do |img|
                    @log.warn "Opening "+img
                    begin
                        File.open(localDir+img, 'wb') do |fo|
                            @log.warn "Writing "+img
                            fo.write open(theURL+img).read
                        end
                        rescue
                        @log.warn "error reading from remote "+theURL+img
                        # there was a problem getting the file,
                        # so remove the file just created
                        # and remove the reference from the list...
                        @log.warn "removing reference from local files"
                        File.delete(localDir+img)
                        #remoteList.delete(img) # DON'T REMOVE FROM THE LIST OTHERWISE WE HAVE NOT WAY OF KNOWING IF THINGS HAVE ALTERED
                    end
                end
                
                #save out the remote file list as the new one
                @log.warn "Saving local array as "+remoteList.inspect+" to "+ @imagesSubDir+'images.txt'
                File.open(@imagesSubDir+'images.txt', 'w') { |f| remoteList.each { |line| f << line << "\n" } }
                
                
                #encode any newly downloaded images
                remoteList.each do |expectedImage|
                    @log.debug "ENCODING "+@imagesSubDir+expectedImage
                    if File.exist?(@imagesSubDir+expectedImage)
                        encode_martel_rle(expectedImage, false)
                    end
                end
                
                #rerun the load images function
                loadImages()
            end
            rescue => e
            @gpio.digital_write @network_led, WiringPi::LOW
            @log.warn e.inspect
        end
    end
    
    def loadImages
        @theImages = []
        #try to load the images.txt file containing the file names to use.
        File.open(@imagesSubDir+"images.txt").each_line do |line|
            @theImages << line.strip
        end
        
        #Make sure there are source images for each of the images in the list...
        @log.warn "raw image list = "+@theImages.inspect
        # remove references to any that have failed
        @theImages.each do |expectedImage|
            @theImages.delete(expectedImage) unless File.exist?(@imagesSubDir+expectedImage)
        end
        
        # perform encoding on any that have been downloaded
        
        # check for any existing encoded file.
        @theImages.each do |expectedImage|
            @log.debug @imagesSubDir+expectedImage
            if File.exist?(@imagesSubDir+expectedImage)
                encode_martel_rle(expectedImage, false) unless File.exist?(@imagesSubDir+expectedImage+@flipString+".bin")
            end
        end
        
        #randomise the list
        @theImages = @theImages.shuffle
        
        @log.warn "usable image list = "+@theImages.inspect
    end
	
    ############################################################################################################
    # PROGRAM STARTS HERE....###################################################################################
    ############################################################################################################
    #puts "log level = "+opts[:loglevel].inspect
    @log = Logging.logger['Happy::Colors']
    @log.add_appenders(
                       Logging.appenders.stdout,
                       Logging.appenders.rolling_file(
                                                      '/var/log/funprinter.log',
                                                      :layout => Logging.layouts.pattern(:pattern => '[%d] %-5l: %m\n'),
                                                      :age => 'monthly',
                                                      :keep => 3,
                                                      :roll_by => 'date'
                                                      )
                       )
                       @log.level = opts[:loglevel]
                       
                       # pull out the command line args
                       absPath = File.expand_path(File.dirname(__FILE__))
                       @log.debug "Script location = "+ absPath
                       
                       theRemoteUrl = "http://www.playflash.co.uk/elly/images/"
                       theLocalDir = absPath+"/images/"
                       pollTime = 5 #in SECONDS
                       timer = Time.now
                       
                       @log.warn "Starting up "+timer.inspect + " version = "+@version
                       @log.debug "Running with "+opts.inspect
                       
                       if opts[:usegpio]
                           # do this before calling load images.
                           # initialize the GPIO port:
                           @gpio = WiringPi::GPIO.new
                           button = 6
                           @network_led = 8
                           @running_led = 9
                           buttonDownFlag = false
                           
                           # initialize the pin functions:
                           @gpio.pin_mode button, WiringPi::INPUT
                           @gpio.pull_up_dn_control button, WiringPi::PUD_UP
                           @gpio.pin_mode @network_led, WiringPi::OUTPUT
                           @gpio.pin_mode @running_led, WiringPi::OUTPUT
                           
                           # turn on the running_led, now that we're running
                           @gpio.digital_write @running_led, WiringPi::HIGH 
                           @gpio.digital_write @network_led, WiringPi::LOW 
                       end
                       
                       
                       opts[:flipped] ? @flipString = "flipped" : @flipString = ""
                       
                       @imagesSubDir = theLocalDir
                       
                       #create an array for all the images
                       @theImages = []
                       
                       if opts[:image] == false and opts[:useimagesfolder] == false
                           @log.warn "no image or images directory specified"
                           exit
                           else
                           if opts[:image] != false 
                               #@imagePath = ARGV[0]
                               #puts ARGV[0].inspect
                               @theImages[0] = @imagePath
                               else
                               loadImages()
                           end
                       end
                       
                       @compress = opts[:forcecompress]
                       
                       @shouldRun = true
                       
                       if opts[:usegpio]
                           
                           connectPrinter()
                           
                           while @shouldRun
                               state = @gpio.digital_read(button)
                               if state == 0 && !buttonDownFlag
                                   @log.debug "Button DOWN"
                                   buttonDownFlag = true
                                   elsif state == 1 && buttonDownFlag
                                   @log.debug "Button UP"
                                   buttonDownFlag = false
                                   @imagePath = getNextImage(@imagePath)
                                   encode_martel_rle(@imagePath, true)
                               end
                               
                               #puts "signals = "+@sp.signals.inspect
                               
                               sleep 0.1 # prevents 90% CPU usage
                               
                               #poll for any new images
                               t = Time.now
                               if timer < t
                                   # check for images
                                   @gpio.digital_write @network_led, WiringPi::LOW
                                   sleep 0.1
                                   @gpio.digital_write @network_led, WiringPi::HIGH
                                   checkRemote(theRemoteUrl, theLocalDir)
                                   timer = t + pollTime
                               end
                               
                           end
                           
                           
                           @gpio.digital_write @running_led, WiringPi::LOW
                           @gpio.digital_write @network_led, WiringPi::LOW
                           disconnectPrinter()
                           
                           
                           else
                           
                           #just print the image, don't worry about anything else
                           connectPrinter()
                           
                           @imagePath = getNextImage(@imagePath)
                           encode_martel_rle(@imagePath, true)
                           
                           disconnectPrinter()
                           
                           @gpio.digital_write @running_led, WiringPi::LOW
                           
                           exit()
                           
                       end
