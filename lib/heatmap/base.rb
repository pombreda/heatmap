module Heatmap
  class Base
    UNPROCESSED_PIXEL = [255,0,0,0] # Fill the picture with these pixels which should be distinguishable from the transparent pixel so we can tell if the pixel has been processed
    TRANSPARENT_PIXEL = [0,0,0,0]

    # OPTIONS:
    #  :bounds => [max_lat, max_lng, min_lat, min_lng]
    #  :height => height in px of the output image (width is determined by the bounding box aspect ratio)
    #  :effect_distance => distance in decimal degrees over which we ignore the influence of points
    #  :legend => a hash of rgba colour stops to colour the map by
    #    e.g.  {1    => [235, 46, 46, 255],
    #           0.5  => [253, 253, 45, 255],
    #           0.25 => [0, 158, 84, 255],
    #           0    => [50, 52, 144, 255]}

    def initialize(points, bounds, options = {})
      @options = options.reverse_merge :effect_distance => 0.01, :bounds => nil

      @min_lat, @min_lng, @max_lat, @max_lng = bounds

      # Determine the dimensions of the output image
      @output_height = @options[:height]
      @output_width  = @options[:width]

      @points = optimize_points(points)

      # Unless a legend has been specified, colour everything based on the max value
      if @options[:legend]
        @options[:legend] = @options[:legend].sort_by {|k,v| -k } # Ensure the legend is sorted descending
      else
        # max_val = points.collect(&:value).max
        # points.each{|p| p.value = p.value / max_val}
        @options[:legend] = {
          1 => [235, 46, 46, 255], # red
          0.5  => [253, 253, 45, 255], # yellow
          0.25  => [0, 158, 84, 255], # green
          0    => [50, 52, 144, 255] # blue
        }
      end

      # Build pixels in scanline order, left to right, top to bottom
      pixels = Array.new(@output_height) { Array.new(@output_width, UNPROCESSED_PIXEL) }

      effect_distance_in_px = ll_to_pixel(0, @options[:effect_distance])[0] - ll_to_pixel(0, 0)[0] + 1 # Round up so edges don't get clipped
      @points.each do |point|
        print '.'

        # Only render the pixels that are affected by a point
        x, y = ll_to_pixel(point.lat, point.lng)
        x_range = Range.new([x - effect_distance_in_px, 0].max, [x + effect_distance_in_px, @output_width].min, true)
        y_range = Range.new([y - effect_distance_in_px, 0].max, [y + effect_distance_in_px, @output_height].min, true)

        y_range.each do |y|
          x_range.each do |x|
            next unless pixels[y][x] == UNPROCESSED_PIXEL # Only render each pixel once, even though renderable areas overlap

            pixels[y][x] = render_pixel(*pixel_to_ll(x,y)).collect do |value|
              (value.to_f * Magick::QuantumRange / 255).round # Scale to 16bit values
            end
          end
        end

        # Mark each site if it appears on the image
        # pixels[y][x] = [Magick::QuantumRange, Magick::QuantumRange, Magick::QuantumRange, Magick::QuantumRange] if pixels[y] && pixels[y][x]
      end

      pixels.flatten! # pixels need to be in a flat array

      @image = Magick::Image.constitute(@output_width, @output_height, "RGBA", pixels)
    end

    def image
      @image.to_blob do |image|
        image.format = 'png'
      end
    end

    def save(filename)
      @image.write(filename)
    end

    private

    def optimize_points(points)
      # Select only the points that will have an effect on the output image
      points.select do |point|
        @min_lat - @options[:effect_distance] <= point.lat &&
        @max_lat + @options[:effect_distance] >= point.lat &&
        @min_lng - @options[:effect_distance] <= point.lng &&
        @max_lng + @options[:effect_distance] >= point.lng
      end
    end

    # NOTE: this calculation is not accurate for extreme latitudes
    def pixel_to_ll(x,y)
      delta_lat = @max_lat-@min_lat
      delta_lng = @max_lng-@min_lng

      # x is lng, y is lat
      # 0,0 is @min_lng, @max_lat

      x_frac = x.to_f / @output_width
      y_frac = y.to_f / @output_height

      lng = @min_lng + x_frac * delta_lng
      lat = @max_lat - y_frac * delta_lat


      calc_x, calc_y = ll_to_pixel(lat, lng)

      if (calc_x-x).abs > 1 || (calc_y-y).abs > 1
        puts "Mismatch: #{x}, #{y} => #{calc_x} #{calc_y}"
      end

      return lat, lng
    end

    # NOTE: this calculation is not accurate for extreme latitudes
    def ll_to_pixel(lat,lng)
      adj_lat = lat - @min_lat
      adj_lng = lng - @min_lng

      delta_lat = @max_lat - @min_lat
      delta_lng = @max_lng - @min_lng

      # x is lng, y is lat
      # 0,0 is @min_lng, @max_lat

      lng_frac = adj_lng / delta_lng
      lat_frac = adj_lat / delta_lat

      x = (lng_frac * @output_width).to_i
      y = ((1-lat_frac) * @output_height).to_i

      return x, y
    end

    # Distance between two points in 2D space
    def distance(x1,y1,x2,y2)
      Math.sqrt((x1-x2)*(x1-x2) + (y1-y2)*(y1-y2))
    end

    def render_pixel
      raise NotImplementedError
    end

    def colour(val)
      floor = @options[:legend].detect{|key, value| val >= key }
      ceiling = @options[:legend].to_a.reverse.detect{|key, value| val < key }

      if ceiling && floor
        blend(ceiling[1], floor[1], (val - floor[0]).to_f / (ceiling[0] - floor[0]))
      elsif floor
        floor[1]
      elsif ceiling
        ceiling[1]
      end
    end

    # Bias is 0..1, how much of colour one to use
    def blend(colour1, colour2, bias)
      colour1 = colour1.collect{|channel| channel * bias}
      colour2 = colour2.collect{|channel| channel * (1 - bias)}
      blended = colour1.each_with_index.collect{|channel, index| (channel.to_f + colour2[index])}
      return blended
    end
  end
end
