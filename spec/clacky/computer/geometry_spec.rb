# frozen_string_literal: true

require "spec_helper"
require File.expand_path(
  "../../../lib/clacky/default_extensions/computer-use/lib/computer/geometry", __dir__
)

RSpec.describe Clacky::Computer::Geometry do
  describe ".fit" do
    it "downscales to max width preserving aspect ratio" do
      expect(described_class.fit(3024, 1964, 1512)).to eq([1512, 982])
    end

    it "never upscales" do
      expect(described_class.fit(800, 600, 1512)).to eq([800, 600])
    end

    it "keeps size when exactly at max width" do
      expect(described_class.fit(1512, 982, 1512)).to eq([1512, 982])
    end

    it "ignores a non-positive max width" do
      expect(described_class.fit(3024, 1964, 0)).to eq([3024, 1964])
    end

    it "never produces a zero height" do
      expect(described_class.fit(3024, 2, 1512)).to eq([1512, 1])
    end
  end

  describe "Display" do
    let(:main_display) do
      described_class::Display.new(1, 0, 0, 1512, 982, 3024, 1964, true, true, true)
    end

    let(:side_display) do
      described_class::Display.new(2, 1512, 0, 1920, 1080, 1920, 1080, false, false, true)
    end

    it "computes the backing scale factor" do
      expect(main_display.scale).to eq(2.0)
      expect(side_display.scale).to eq(1.0)
    end

    it "reports membership in point space" do
      expect(main_display.contains?(0, 0)).to be true
      expect(main_display.contains?(1511.9, 981.9)).to be true
      expect(main_display.contains?(1512, 0)).to be false
      expect(side_display.contains?(1512, 0)).to be true
      expect(side_display.contains?(1511.9, 0)).to be false
    end

    it "round-trips through to_h" do
      hash = side_display.to_h
      expect(hash[:origin]).to eq([1512, 0])
      expect(hash[:points]).to eq([1920, 1080])
      expect(hash[:scale]).to eq(1.0)
      expect(hash[:origin_known]).to be true
    end
  end

  describe ".pick_display" do
    let(:displays) do
      [
        described_class::Display.new(1, 0, 0, 1512, 982, 3024, 1964, true, true, true),
        described_class::Display.new(2, 1512, 0, 1920, 1080, 1920, 1080, false, false, true)
      ]
    end

    it "picks the display containing the point" do
      expect(described_class.pick_display(displays, 2000, 500).id).to eq(2)
      expect(described_class.pick_display(displays, 100, 100).id).to eq(1)
    end

    it "falls back to the main display when the point is nowhere" do
      expect(described_class.pick_display(displays, -500, -500).id).to eq(1)
    end
  end

  describe "Capture" do
    def capture(origin_x:, origin_y:, points:, image:)
      described_class::Capture.new(
        origin_x: origin_x, origin_y: origin_y,
        points_width: points[0], points_height: points[1],
        path: "/tmp/x.png", model_path: "/tmp/x.png",
        image_width: image[0], image_height: image[1]
      )
    end

    it "maps image pixels to global points on a 1:1 Retina downscale" do
      cap = capture(origin_x: 0, origin_y: 0, points: [1512, 982], image: [1512, 982])
      expect(cap.image_to_points(756, 491)).to eq([756.0, 491.0])
      expect(cap.points_to_image(756, 491)).to eq([756.0, 491.0])
    end

    it "maps through a full-resolution Retina capture" do
      cap = capture(origin_x: 0, origin_y: 0, points: [1512, 982], image: [3024, 1964])
      expect(cap.image_to_points(1512, 982)).to eq([756.0, 491.0])
      expect(cap.points_per_image_pixel_x).to eq(0.5)
    end

    it "offsets coordinates for a secondary display" do
      cap = capture(origin_x: 1512, origin_y: 0, points: [1920, 1080], image: [1920, 1080])
      expect(cap.image_to_points(100, 50)).to eq([1612.0, 50.0])
      expect(cap.points_to_image(1612, 50)).to eq([100.0, 50.0])
    end

    it "offsets a zoomed region" do
      cap = capture(origin_x: 200, origin_y: 300, points: [400, 250], image: [800, 500])
      expect(cap.image_to_points(400, 250)).to eq([400.0, 425.0])
    end

    it "bounds-checks in image space" do
      cap = capture(origin_x: 0, origin_y: 0, points: [1512, 982], image: [1512, 982])
      expect(cap.include?(0, 0)).to be true
      expect(cap.include?(1511, 981)).to be true
      expect(cap.include?(1512, 981)).to be false
      expect(cap.include?(-1, 10)).to be false
    end

    it "defaults model_path to path" do
      cap = described_class::Capture.new(
        origin_x: 0, origin_y: 0, points_width: 10, points_height: 10,
        path: "/tmp/full.png", model_path: nil, image_width: 10, image_height: 10
      )
      expect(cap.model_path).to eq("/tmp/full.png")
    end
  end
end
