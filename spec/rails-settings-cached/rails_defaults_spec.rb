require 'spec_helper'

describe 'Rails >= 5 framework defaults' do
  it 'runs this harness with belongs_to required by default' do
    expect(ActiveRecord::Base.belongs_to_required_by_default).to be true
  end

  it 'saves a global setting (thing NULL) even though belongs_to is required by default' do
    expect { Setting.global_key = 'x' }.not_to raise_error
    row = Setting.unscoped.find_by(var: 'global_key')
    expect(row.thing_type).to be_nil
    expect(row.thing_id).to be_nil
  end
end
