require 'spec_helper'

describe RailsSettings::YAMLCoder do
  class YamlCoderWidget
    attr_accessor :a
    def initialize(a = nil) = @a = a
    def ==(other) = other.is_a?(YamlCoderWidget) && other.a == a
  end

  after do
    RailsSettings.config.yaml_permitted_classes = nil
    RailsSettings.config.yaml_unsafe_load = nil
    RailsSettings.config.yaml_aliases = nil
  end

  it 'decodes HashWithIndifferentAccess by default (MEX partner settings written from params)' do
    yaml = ActiveSupport::HashWithIndifferentAccess.new('a' => 1).to_yaml
    expect(yaml).to include('!ruby/hash:ActiveSupport::HashWithIndifferentAccess')
    decoded = described_class.load(yaml)
    expect(decoded).to eq('a' => 1)
    expect(decoded).to be_a(ActiveSupport::HashWithIndifferentAccess)
  end

  it 'decodes Symbol, Time and Date by default' do
    expect(described_class.load({ k: :v }.to_yaml)).to eq(k: :v)
    expect(described_class.load(Date.new(2026, 9, 11).to_yaml)).to eq Date.new(2026, 9, 11)
    expect(described_class.load(Time.utc(2026, 9, 11, 12).to_yaml)).to eq Time.utc(2026, 9, 11, 12)
  end

  it 'includes ActiveRecord.yaml_column_permitted_classes' do
    expect(RailsSettings.config.yaml_permitted_classes).to include(*ActiveRecord.yaml_column_permitted_classes)
  end

  it 'rejects classes outside the allow-list' do
    expect { described_class.load(YamlCoderWidget.new(1).to_yaml) }.to raise_error(Psych::DisallowedClass)
  end

  it 'decodes a class once it is added to the config' do
    RailsSettings.configure { |c| c.yaml_permitted_classes = c.yaml_permitted_classes + [YamlCoderWidget] }
    expect(described_class.load(YamlCoderWidget.new(1).to_yaml)).to eq YamlCoderWidget.new(1)
  end

  it 'uses unsafe_load when configured' do
    RailsSettings.config.yaml_unsafe_load = true
    expect(described_class.load(YamlCoderWidget.new(1).to_yaml)).to eq YamlCoderWidget.new(1)
  end

  it 'returns nil for nil input' do
    expect(described_class.load(nil)).to be_nil
  end

  it 'is used for Setting rows' do
    Setting.hwia = ActiveSupport::HashWithIndifferentAccess.new('a' => 1)
    Rails.cache.clear
    expect(Setting.hwia).to be_a(ActiveSupport::HashWithIndifferentAccess)
    expect(Setting.hwia).to eq('a' => 1)
  end

  it 'is used for the defaults file (aliases and ERB still work)' do
    expect(RailsSettings::Default.instance['str']).to eq 'hello in test'
    expect(RailsSettings::Default.instance['script']).to eq 6
  end
end
